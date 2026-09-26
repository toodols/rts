"""unit_defs/vehicle_t2.luau `mantis` (BAR's legvcarry, in Cortex dress): a drone carrier.

No gun of its own: a broad tracked hull whose back is a flight deck -- a dark landing pad with glowing marks for
the drone it launches and recovers -- a team-colour command island off to one side like a carrier's, with a
spinning radar on its mast, and hangar pods along both flanks."""

from .shared import common
from .shared import palette
from .shared import vehicle_t2 as v

CATEGORY = "entity"
DEF = "mantis"


def generate(params):
    m = common.Materials(params["color"], palette.HEADLIGHT)
    objects = []

    L, W = 5.0, 3.0
    hl, hw = L / 2.0, W / 2.0
    deck = 1.0

    # Footprint first: the hull, a sloped bow and a long flat deck, flared out over the tracks (16 tris).
    hull = v.loft("hull", [
        (-hl, 0.95, 1.12, 0.36, 0.62),
        (-hl + 0.8, 1.0, 1.2, 0.34, deck),
        (hl, 1.0, 1.2, 0.34, deck),
    ])
    objects.append(m.body(hull))
    for side in (-1, 1):
        objects.append(m.trim(v.track(f"track_{side}", side * 1.2, L - 0.1, 0.6, 0.56)))
        # hangar pods along the flanks (8 tris each), the drone's bays
        pod = common.block(f"pod_{side}", 0.38, 2.9, 0.5, top=(0.28, 2.7), top_offset=(side * 0.04, 0.0), at=(side * 1.3, 0.85, deck - 0.12), drop=("bottom", "left" if side > 0 else "right"))
        objects.append(m.accent(pod))

    # Flight deck: a dark hexagonal pad (4 tris) with glowing landing marks (2 each).
    pz = deck + 0.01
    cy = 0.9
    pad = v.decal("pad", [(0.0 + 0.95 * c, cy + 0.95 * s, pz) for c, s in
                          ((1.0, 0.0), (0.5, 0.866), (-0.5, 0.866), (-1.0, 0.0), (-0.5, -0.866), (0.5, -0.866))])
    objects.append(m.trim(pad))
    gz = pz + 0.01
    for i, (x0, y0, x1, y1) in enumerate(((-0.5, cy - 0.45, -0.36, cy + 0.45), (0.36, cy - 0.45, 0.5, cy + 0.45),
                                          (-0.36, cy - 0.07, 0.36, cy + 0.07))):
        objects.append(m.glow(v.decal(f"mark_{i}", [(x0, y0, gz), (x1, y0, gz), (x1, y1, gz), (x0, y1, gz)])))

    # Bow: a team-colour chevron plate on the glacis and headlights (2 tris each).
    by0, bz0, by1, bz1 = -hl, 0.62, -hl + 0.8, deck

    def bow(x, t, lift=0.012):
        return (x, by0 + (by1 - by0) * t - lift * 0.43, bz0 + (bz1 - bz0) * t + lift * 0.9)

    up = (0.0, -(bz1 - bz0), by1 - by0)
    objects.append(m.accent(v.decal("bow_plate", [bow(-0.5, 0.35), bow(0.5, 0.35), bow(0.6, 0.95), bow(-0.6, 0.95)], up=up)))
    for side in (-1, 1):
        objects.append(m.glow(v.decal(f"headlight_{side}", [bow(side * 0.7, 0.2), bow(side * 1.0, 0.2),
                                                            bow(side * 1.0, 0.45), bow(side * 0.7, 0.45)], up=up)))

    # Command island off to the right, forward of the pad (10 tris), with a mast (6).
    ix, iy = 0.62, -1.25
    island = common.block("island", 0.9, 1.3, 0.9, top=(0.6, 0.8), top_offset=(0.05, 0.12), at=(ix, iy, deck), drop=('bottom',))
    objects.append(m.accent(island))
    mast_top = deck + 0.9 + 0.9
    mast, _ = v.rod("mast", 0.07, 0.9, (ix + 0.05, iy + 0.2, deck + 0.9), pitch=90.0, sides=3, front_cap=False)
    objects.append(m.trim(mast))

    # Radar bar spinning on the mast (10 tris).
    radar = common.block("radar_bar", 1.2, 0.14, 0.2, top=(1.2, 0.06), at=(0.0, 0.0, 0.0), drop=('bottom',))
    m.body(radar)
    radar = common.merge("radar", [radar], origin=(ix + 0.05, iy + 0.2, mast_top))
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=2.5))

    return objects
