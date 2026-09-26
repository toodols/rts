"""Synthesizes the game's sound effects from scratch, so every one is ours to upload.

    python tools/sound_pipeline/synth.py            # writes build/<name>.wav and build/<name>.ogg

Needs numpy, scipy and ffmpeg on PATH. Listen with review.py before uploading with upload_sounds.py.

Nothing here is a bare oscillator: tones are FM or detuned stacks, noise is pink or brown rather than white, filters
move over the sound's life, it is saturated for harmonics, and everything is put in a small synthetic room.
"""

import subprocess
import zlib
from typing import Callable

import numpy as np
from scipy.io import wavfile
from scipy.ndimage import maximum_filter1d
from scipy.signal import butter, fftconvolve, iirpeak, sosfilt, sosfiltfilt, tf2sos

from records import BUILD

RATE = 44100
NYQUIST = RATE / 2
rng = np.random.default_rng(7)


def times(seconds: float) -> np.ndarray:
    return np.arange(int(seconds * RATE)) / RATE


def path(*points: tuple[float, float]) -> Callable[[np.ndarray], np.ndarray]:
    """A value gliding through (time, value) points, exponentially between them and held past the ends."""
    at, values = zip(*points)
    logs = np.log(values)
    return lambda t: np.exp(np.interp(t, at, logs))


def phase_of(freq: np.ndarray) -> np.ndarray:
    return 2 * np.pi * np.cumsum(freq) / RATE


def sweep_phase(start_hz: float, end_hz: float, t: np.ndarray, length: float) -> np.ndarray:
    """Phase of an exponential sweep from start_hz to end_hz over `length` seconds, held at end_hz after."""
    return phase_of(path((0, start_hz), (length, end_hz))(t))


def envelope(t: np.ndarray, attack: float, decay: float) -> np.ndarray:
    """A linear attack then an exponential decay with time constant `decay`."""
    rise = np.clip(t / attack, 0, 1) if attack > 0 else np.ones_like(t)
    return rise * np.exp(-np.maximum(t - attack, 0) / decay)


def unit(signal: np.ndarray) -> np.ndarray:
    """Scaled to a standard deviation of one, so layers mix by their loudness rather than their peaks."""
    return signal / (np.std(signal) + 1e-12)


def white(n: int) -> np.ndarray:
    return rng.standard_normal(n)


def coloured(n: int, slope: float) -> np.ndarray:
    """Noise whose power falls off as 1/f**slope: 1 for pink (natural, rushing), 2 for brown (deep, rumbling)."""
    spectrum = np.fft.rfft(rng.standard_normal(n))
    freq = np.fft.rfftfreq(n, 1 / RATE)
    freq[0] = freq[1]
    return unit(np.fft.irfft(spectrum / freq ** (slope / 2), n))


def lowpass(hz: float, order: int = 2) -> np.ndarray:
    return butter(order, min(hz, NYQUIST - 100), btype="low", fs=RATE, output="sos")


def highpass(hz: float, order: int = 2) -> np.ndarray:
    return butter(order, hz, btype="high", fs=RATE, output="sos")


def bandpass(hz: float, width: float) -> np.ndarray:
    """A band from hz / width to hz * width."""
    return butter(2, [hz / width, min(hz * width, NYQUIST - 100)], btype="band", fs=RATE, output="sos")


def resonance(hz: float, q: float) -> np.ndarray:
    """A narrow resonant peak: noise through it whistles, a click through it rings."""
    return tf2sos(*iirpeak(min(hz, NYQUIST - 200), q, fs=RATE))


def filtered(signal: np.ndarray, sos: np.ndarray) -> np.ndarray:
    return sosfilt(sos, signal)


def band(signal: np.ndarray, low: float, high: float) -> np.ndarray:
    return sosfilt(butter(2, [low, high], btype="band", fs=RATE, output="sos"), signal)


def swept(signal: np.ndarray, hz: Callable[[np.ndarray], np.ndarray], design: Callable[[float], np.ndarray],
          block: int = 128) -> np.ndarray:
    """`signal` through the filter `design` makes for a frequency that follows `hz` over time."""
    out = np.zeros_like(signal)
    zi = None
    for begin in range(0, len(signal), block):
        sos = design(float(hz(np.array([begin / RATE]))[0]))
        if zi is None:
            zi = np.zeros((sos.shape[0], 2))
        out[begin : begin + block], zi = sosfilt(sos, signal[begin : begin + block], zi=zi)
    return out


def saturate(signal: np.ndarray, drive: float, bias: float = 0.08) -> np.ndarray:
    """Soft clipping, a little lopsided so it adds even harmonics (warmth) as well as odd ones (grit)."""
    shaped = np.tanh(drive * (signal + bias)) - np.tanh(drive * bias)
    return sosfilt(highpass(20), shaped)


def fm(phase: np.ndarray, ratio: float, index: np.ndarray | float) -> np.ndarray:
    """A carrier at `phase` frequency-modulated by one at `ratio` times it: the brightness follows `index`."""
    return np.sin(phase + index * np.sin(ratio * phase))


def saw(phase: np.ndarray, top_hz: float, fundamental_hz: float) -> np.ndarray:
    """A band-limited sawtooth (no aliasing fizz), with harmonics up to about `top_hz`."""
    out = np.zeros_like(phase)
    for k in range(1, max(2, int(top_hz / fundamental_hz)) + 1):
        out += np.sin(k * phase) / k
    return out


def slow_wander(n: int, hz: float) -> np.ndarray:
    """A random wobble between -1 and 1 that changes about `hz` times a second."""
    wander = sosfilt(lowpass(hz), rng.standard_normal(n))
    return wander / (np.max(np.abs(wander)) + 1e-12)


def reverb(signal: np.ndarray, seconds: float, wet: float, brightness: float = 5000) -> np.ndarray:
    """`signal` in a room that dies away over `seconds` (to -60 dB), its tail darkening as it goes."""
    # whatever is still sounding at the end of the dry signal is faded out, not cut off with a click
    signal = signal.copy()
    fade = min(int(0.25 * RATE), len(signal))
    signal[-fade:] *= np.cos(np.linspace(0, np.pi / 2, fade)) ** 2
    n = int(seconds * RATE)
    t = np.arange(n) / RATE
    tail = swept(rng.standard_normal(n) * 10 ** (-3 * t / seconds), path((0, brightness), (seconds, brightness / 6)),
                 lowpass)
    impulse = np.zeros(n)
    predelay = int(0.012 * RATE)
    impulse[predelay:] = tail[: n - predelay]
    for delay, gain in ((0.005, 0.6), (0.011, 0.45), (0.017, 0.35), (0.026, 0.25), (0.037, 0.18)):
        impulse[int(delay * RATE)] += gain * rng.choice((-1, 1))
    impulse /= np.sqrt(np.sum(impulse**2))
    room = fftconvolve(signal, impulse)
    return np.pad(signal, (0, len(room) - len(signal))) + wet * room


def trimmed(signal: np.ndarray, floor_db: float = -60, fade: float = 0.03, most: float | None = None) -> np.ndarray:
    """Cut once it has fallen below `floor_db` of its peak for good, or at `most` seconds, fading out the last `fade`."""
    loud = np.nonzero(np.abs(signal) > np.max(np.abs(signal)) * 10 ** (floor_db / 20))[0]
    end = loud[-1] + 1 if most is None else min(loud[-1] + 1, int(most * RATE))
    signal = signal[:end].copy()
    n = min(int(fade * RATE), len(signal))
    signal[-n:] *= np.linspace(1, 0, n) ** 2
    return signal


def normalize(signal: np.ndarray, peak_db: float = -1.0) -> np.ndarray:
    return signal / np.max(np.abs(signal)) * 10 ** (peak_db / 20)


def limited(signal: np.ndarray, most_db: float = 4.0) -> np.ndarray:
    """The sharpest peaks held down by up to `most_db`, smoothly, so a sound whose hit is far louder than its body can
    be made louder overall without losing the hit. What gets past that is made up by the Sound's in-game volume."""
    held = maximum_filter1d(np.abs(signal), int(0.005 * RATE))
    level = sosfiltfilt(lowpass(20), held)
    ceiling = np.max(level) * 10 ** (-most_db / 20)
    return signal * np.minimum(1, ceiling / np.maximum(level, 1e-9))


def loudness_db(signal: np.ndarray) -> float:
    """How loud the loudest tenth of a second is, which is closer to how loud it seems than its peak."""
    window = int(0.1 * RATE)
    starts = range(0, max(1, len(signal) - window), window // 4)
    return 20 * np.log10(max(np.sqrt(np.mean(signal[i : i + window] ** 2)) for i in starts))


def crackle(t: np.ndarray, count: int, spread: float) -> np.ndarray:
    """Debris: little snaps scattered over the first `spread` seconds and thinning out, each ringing at its own pitch."""
    out = np.zeros_like(t)
    for _ in range(count):
        at = int(rng.exponential(spread / 3) * RATE)
        if at >= len(t) - 1200:
            continue
        length = 1200
        snap = rng.standard_normal(length) * np.exp(-np.arange(length) / rng.uniform(25, 90))
        snap = sosfilt(bandpass(rng.uniform(1200, 6000), 1.6), snap)
        out[at : at + length] += snap * rng.uniform(0.3, 1)
    return unit(out)


def laser() -> np.ndarray:
    """A bright "pew": an FM tone diving from 2.4 kHz, its metallic edge melting away as it falls, over a zap."""
    t = times(0.3)
    n = len(t)
    freq = path((0, 2400), (0.15, 240), (0.3, 200))(t)
    index = 0.3 + 2.0 * envelope(t, 0.001, 0.04)
    tone = sum(fm(phase_of(freq * (1 + detune)), 1.5, index) for detune in (-0.009, 0, 0.011)) / 3
    zap = unit(band(white(n), 2500, 9000)) * envelope(t, 0.0005, 0.006)
    sizzle = unit(band(white(n), 4000, 12000)) * envelope(t, 0.001, 0.03)
    dry = saturate(tone * envelope(t, 0.002, 0.06) + 0.12 * zap + 0.03 * sizzle, 1.6)
    return trimmed(reverb(dry, 0.5, 0.2, 6000))


def frying(n: int, rate: float) -> np.ndarray:
    """Grains of sizzle coming and going about `rate` times a second, as fat spits in a pan, between 0.3 and 1."""
    grains = np.zeros(n)
    count = int(rate * n / RATE)
    grains[rng.integers(0, n, count)] = rng.uniform(0.3, 1, count)
    grains = sosfilt(lowpass(90), grains)
    return 0.3 + 0.7 * grains / (np.max(grains) + 1e-12)


def heat_ray() -> np.ndarray:
    """A heat ray: heavier than the laser's "pew". A thump as it lights, then a searing roar - a growl of detuned low
    saws that sags in pitch as it burns - with the air frying and hissing around it, held for as long as a beam
    lasts before it dies away."""
    t = times(0.9)
    n = len(t)
    burn = np.clip(t / 0.012, 0, 1) * np.exp(-np.maximum(t - 0.32, 0) / 0.16)
    shimmer = np.clip(1 + 0.2 * slow_wander(n, 22), 0.6, 1.4)
    base = path((0, 150), (0.08, 118), (0.9, 92))(t)
    growl = sum(saw(phase_of(base * ratio), 4000, 150 * ratio) for ratio in (0.992, 1.0, 1.011, 2.003)) / 4
    growl = swept(growl, path((0, 5000), (0.1, 2400), (0.5, 1100), (0.9, 400)), lowpass)
    # a rasp: the growl's octave below, frequency-modulated so it snarls rather than hums
    rasp = fm(phase_of(base * 0.5), 1.5, 1.8 + 1.2 * envelope(t, 0.005, 0.08))
    sizzle = unit(sosfilt(highpass(2500), coloured(n, 1))) * frying(n, 350)
    hiss = unit(band(white(n), 5000, 14000)) * envelope(t, 0.001, 0.05)
    thump_phase = sweep_phase(150, 45, t, 0.12)
    thump = (np.sin(thump_phase) + 0.3 * np.sin(2 * thump_phase)) * envelope(t, 0.002, 0.09)
    crack = unit(band(white(n), 1000, 6000)) * envelope(t, 0.0005, 0.008)
    dry = saturate(
        (0.8 * unit(growl) + 0.35 * rasp) * burn * shimmer + 0.38 * sizzle * burn + 0.08 * hiss + 1.0 * thump
        + 0.25 * crack,
        2.2,
    )
    return trimmed(reverb(dry, 0.8, 0.22, 4500))


def pulsar() -> np.ndarray:
    """The Pulsar's tachyon accelerator: the heaviest beam there is. A giant "pew" - a metallic FM tone diving from
    3 kHz to a growl - over a sub drop and a blast of air, then the beam itself for its second and a half: a deep hum
    throbbing as its sheath does, crackling with arcs, dying away into a long tail."""
    t = times(2.1)
    n = len(t)
    freq = path((0, 3200), (0.05, 900), (0.3, 110), (2.1, 70))(t)
    index = 0.8 + 4.0 * envelope(t, 0.002, 0.07)
    dive = sum(fm(phase_of(freq * (1 + detune)), 1.5, index) for detune in (-0.012, 0, 0.009)) / 3
    dive *= envelope(t, 0.004, 0.22)
    sub_phase = sweep_phase(110, 28, t, 0.5)
    sub = (np.sin(sub_phase) + 0.35 * np.sin(2 * sub_phase)) * envelope(t, 0.004, 0.4)
    blast = swept(coloured(n, 1), path((0, 8000), (0.15, 1500), (0.6, 300)), lowpass) * envelope(t, 0.001, 0.12)
    # the beam: a stack of low saws, pulsing about eleven times a second as the drawn beam's sheath throbs
    hold = np.clip(t / 0.05, 0, 1) * np.cos(np.clip((t - 1.2) / 0.5, 0, 1) * np.pi / 2) ** 2
    throb = 0.5 + 0.5 * np.sin(2 * np.pi * 11 * t + 0.3 * slow_wander(n, 4))
    hum_hz = path((0, 58), (1.7, 52))(t)
    hum = sum(saw(phase_of(hum_hz * ratio), 1600, 58 * ratio) for ratio in (0.995, 1.0, 1.007, 1.502, 2.004)) / 5
    hum = swept(hum, path((0, 2200), (0.3, 900), (1.7, 400)), lowpass)
    arcs = unit(sosfilt(bandpass(4000, 2.2), crackle(t, 140, 1.4))) * frying(n, 60)
    arcs *= hold
    crack = unit(band(white(n), 1500, 9000)) * envelope(t, 0.0005, 0.01)
    dry = saturate(
        1.0 * dive + 1.4 * sub + 0.7 * blast + 0.4 * unit(hum) * hold * throb + 0.1 * arcs + 0.3 * crack,
        2.0,
    )
    return trimmed(reverb(dry, 1.6, 0.3, 3000), fade=0.3, most=2.8)


def cannon() -> np.ndarray:
    """A plasma cannon's thud: a dropping thump, a crack, and a burst of darkening noise ringing in the barrel."""
    t = times(0.7)
    n = len(t)
    thump_phase = sweep_phase(170, 46, t, 0.1)
    thump = (np.sin(thump_phase) + 0.3 * np.sin(2 * thump_phase)) * envelope(t, 0.002, 0.11)
    crack = unit(band(white(n), 1500, 7000)) * envelope(t, 0.0005, 0.01)
    blast = swept(coloured(n, 1), path((0, 5000), (0.25, 300), (0.7, 150)), lowpass) * envelope(t, 0.001, 0.07)
    barrel = unit(filtered(blast, resonance(190, 5))) * envelope(t, 0.002, 0.08)
    dry = saturate(1.1 * thump + 0.5 * blast + 0.25 * barrel + 0.2 * crack, 1.8)
    return trimmed(reverb(dry, 0.9, 0.25, 4000))


def explosion_small() -> np.ndarray:
    """A unit going up: a crunching crack, a rolling burst that darkens as it dies, a sub thump and debris."""
    t = times(1.5)
    n = len(t)
    burst = swept(coloured(n, 1), path((0, 6000), (0.15, 1800), (0.9, 160)), lowpass) * envelope(t, 0.003, 0.26)
    crunch = saturate(unit(band(white(n), 400, 2500)) * envelope(t, 0.001, 0.05), 3)
    thump_phase = sweep_phase(120, 34, t, 0.3)
    thump = (np.sin(thump_phase) + 0.25 * np.sin(2 * thump_phase)) * envelope(t, 0.003, 0.2)
    body = saturate(0.9 * burst + 1.2 * thump + 0.35 * crunch, 2.0)
    return trimmed(reverb(body + 0.08 * crackle(t, 45, 0.7), 1.4, 0.28, 3500))


def explosion_large() -> np.ndarray:
    """A building or a big shell: a slower, deeper blast whose rumble rolls on in uneven waves."""
    t = times(4.0)
    n = len(t)
    noise = coloured(n, 2) + 0.6 * coloured(n, 1)
    burst = swept(noise, path((0, 2500), (0.2, 900), (2.5, 80)), lowpass) * envelope(t, 0.015, 0.8)
    wobble = np.clip(1 + 0.45 * slow_wander(n, 6), 0.3, 1.8)
    thump_phase = sweep_phase(70, 22, t, 0.6)
    thump = (np.sin(thump_phase) + 0.3 * np.sin(2 * thump_phase)) * envelope(t, 0.006, 0.45)
    body = saturate(0.7 * burst * wobble + 1.2 * thump, 2.0)
    return trimmed(reverb(body + 0.03 * crackle(t, 90, 1.5), 2.2, 0.3, 2000))


def dgun() -> np.ndarray:
    """The D-gun: a tsunami. A deep impact, then a wall of low water that surges up, crests and breaks with a
    spray, and a growling mass under it that washes out, all inside two seconds."""
    t = times(1.6)
    n = len(t)
    swell = np.clip(t / 0.18, 0, 1) ** 1.5 * np.exp(-np.maximum(t - 0.22, 0) / 0.42)
    churn = np.clip(1 + 0.35 * slow_wander(n, 9), 0.4, 1.6)
    # the wave itself: deep noise whose top opens up as it rises and closes again as it rolls away
    water = 0.8 * coloured(n, 2) + 0.5 * coloured(n, 1)
    wave = swept(water, path((0, 160), (0.28, 1300), (0.55, 600), (1.6, 100)), lambda hz: lowpass(hz, 4))
    # the mass of it: a stack of detuned low saws sinking in pitch
    base = path((0, 62), (0.25, 48), (1.6, 34))(t)
    roar = sum(saw(phase_of(base * ratio), 1500, 62 * ratio) for ratio in (0.988, 1.0, 1.015, 1.498)) / 4
    roar = swept(roar, path((0, 300), (0.28, 900), (1.6, 140)), lowpass)
    # the crest breaking
    crash_at = np.maximum(t - 0.3, 0)
    crash = swept(coloured(n, 1), path((0, 3000), (0.36, 3000), (0.9, 250)), lowpass)
    crash *= (t >= 0.3) * envelope(crash_at, 0.05, 0.22)
    spray = unit(band(white(n), 2500, 7500)) * np.exp(-(((t - 0.38) / 0.18) ** 2)) * churn
    impact_phase = sweep_phase(90, 30, t, 0.25)
    impact = (np.sin(impact_phase) + 0.35 * np.sin(2 * impact_phase)) * envelope(t, 0.005, 0.25)
    thud = unit(band(white(n), 200, 1500)) * envelope(t, 0.001, 0.03)
    dry = saturate(
        0.9 * wave * swell * churn + 0.64 * unit(roar) * swell + 0.5 * crash + 0.06 * spray + 1.1 * impact
        + 0.3 * thud,
        1.6,
    )
    return trimmed(reverb(dry, 1.1, 0.28, 2500), fade=0.3, most=1.9)


def flyby(source: np.ndarray, position: Callable[[np.ndarray], np.ndarray], seconds: float,
          ground: float = 0.55) -> np.ndarray:
    """`source`, sounding from `position(t)` (metres, z up) as it moves, as heard `seconds` long by a listener at head
    height over flat ground: each sample reaches the ear late by its distance over the speed of sound (the Doppler
    shift), quieter by that distance, and darkened by the air it crossed. It is heard a second time off the ground,
    and the two sweeping past each other is the rushing flange of anything fast going by."""
    sound_speed = 343.0
    ear = np.array([0.0, 0.0, 1.7])
    emitted = np.arange(len(source)) / RATE
    where = position(emitted)
    mirrored = where * np.array([[1], [1], [-1]])
    heard = times(seconds)
    out = np.zeros_like(heard)
    distances = []
    for spot, gain, voice in ((where, 1.0, source), (mirrored, ground, sosfilt(lowpass(6000), source))):
        distance = np.linalg.norm(spot - ear[:, None], axis=0)
        arrival = emitted + distance / sound_speed
        out += gain * np.interp(heard + arrival[0], arrival, voice / np.maximum(distance, 1) ** 0.85, left=0, right=0)
        distances.append((arrival - arrival[0], distance))
    arrival, distance = distances[0]
    air = lambda at: np.clip(18000 * (8 / np.interp(at, arrival, distance)) ** 0.8, 1500, 18000)
    return swept(out, air, lowpass)


def anti_air() -> np.ndarray:
    """An anti-air missile: a snap of ignition, then a rocket - fizzing exhaust, a thin high whine and air tearing
    around it - that rips past close by and streaks off, its pitch falling away as it goes."""
    t = times(1.05)
    n = len(t)
    # the exhaust: hissing noise that fizzes and crackles as the fuel burns unevenly
    sparks = np.zeros(n)
    sparks[rng.integers(0, n, 500)] = rng.uniform(0.2, 1, 500)
    fizz = sosfilt(lowpass(250), sparks)
    fizz /= np.max(fizz)
    exhaust = unit(sosfilt(highpass(500), coloured(n, 1))) * (0.6 + 0.8 * fizz)
    # the motor's whine, spooling up, with an inharmonic partial that keeps it from sounding like a pure beep
    whine_hz = path((0, 5000), (0.3, 6800))(t) * (1 + 0.004 * slow_wander(n, 30))
    whine_phase = phase_of(whine_hz)
    whine = fm(whine_phase, 1.0, 0.35) + 0.35 * np.sin(1.47 * whine_phase)
    tearing = unit(band(white(n), 3000, 12000)) * (1 + 0.3 * slow_wander(n, 40))
    ignition = unit(band(white(n), 800, 6000)) * envelope(t, 0.0005, 0.012)
    burn = np.clip(t / 0.01, 0, 1) * np.cos(np.clip((t - 0.95) / 0.1, 0, 1) * np.pi / 2) ** 2
    source = (0.5 * exhaust + 0.35 * whine + 0.3 * tearing) * burn + 0.5 * ignition
    # kept below 13 kHz so that the Doppler rise as it closes in cannot push anything past what can be played
    source = sosfilt(lowpass(12500, 4), saturate(source, 1.2))

    # launched 6 m behind and 4 m to the side, skimming low and nearly level so the ground echo sweeps against it,
    # accelerating to about 300 m/s
    def position(at: np.ndarray) -> np.ndarray:
        along = -6 + 70 * at + 115 * at**2
        return np.stack([along, np.full_like(at, 4.0), 2.5 + 0.04 * (along + 6)])

    return trimmed(reverb(flyby(source, position, 1.6), 0.9, 0.12, 8000))


def click() -> np.ndarray:
    """A short, soft UI tick: a tap that rings for an instant, like a small plastic key."""
    t = times(0.06)
    n = len(t)
    tap = np.zeros(n)
    tap[0] = 1
    tap += 0.3 * white(n) * envelope(t, 0.0002, 0.0015)
    ring = sum(gain * unit(filtered(tap, resonance(hz, q)))
               for hz, q, gain in ((2300, 30, 1.0), (5100, 22, 0.45), (820, 10, 0.35)))
    return trimmed(reverb(ring * envelope(t, 0.0003, 0.012), 0.15, 0.08, 8000), fade=0.005)


def notify() -> np.ndarray:
    """Something wants a look (an ally's ping): two quick rising bell blips, like a radio chirp."""
    t = times(0.2)
    out = np.zeros_like(t)
    for start, hz in ((0.0, 880), (0.06, 1320)):
        local = np.clip(t - start, 0, None)
        index = 1.6 * envelope(local, 0.001, 0.02)
        blip = fm(2 * np.pi * hz * local, 2.0, index) * envelope(local, 0.002, 0.035)
        out += np.where(t >= start, blip, 0)
    return trimmed(reverb(saturate(out, 1.4), 0.4, 0.15, 7000), fade=0.01)


SOUNDS = {
    "laser": laser,
    "heat_ray": heat_ray,
    "pulsar": pulsar,
    "cannon": cannon,
    "explosion_small": explosion_small,
    "explosion_large": explosion_large,
    "dgun": dgun,
    "anti_air": anti_air,
    "click": click,
    "notify": notify,
}


def main():
    BUILD.mkdir(exist_ok=True)
    global rng
    for name, make in SOUNDS.items():
        # each sound draws its noise from its own seed, so changing one never changes another
        rng = np.random.default_rng(zlib.crc32(name.encode()))
        signal = normalize(limited(make()))
        wav = BUILD / f"{name}.wav"
        wavfile.write(wav, RATE, (signal * 32767).astype(np.int16))
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(wav), "-c:a", "libvorbis", "-q:a", "6", str(BUILD / f"{name}.ogg")],
            check=True,
        )
        print(f"{name}: {len(signal) / RATE:.2f}s, loudest 100 ms at {loudness_db(signal):.1f} dB")


if __name__ == "__main__":
    main()
