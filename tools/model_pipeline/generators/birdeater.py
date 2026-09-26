"""unit_defs/hover_t1.luau `birdeater` (BAR corah): Cortex's anti-air hovercraft.

A chunky gunmetal hull with a sloped
glacis and a lit cockpit slit rides on a dark rubber skirt that flares out past it at the bottom; a big
team-coloured ducted fan stands on the rear deck, its dark fan face showing through it. Forward of it, on
a squat dark turret ring, sits the defining piece: a team-coloured missile box pitched up at the sky with three
missile noses poking out of its dark mouth (the three-missile burst). Only the launcher and its ring turn, with
weapon 1.

The unit faces Blender -Y (Roblox +Z). Origin = ground, centred on the footprint.
"""

import math

from .shared import common
from .shared import palette
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "birdeater"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 3.24, "height": 1.62}
MOUNTS = {
    1: {"pivot": (0, 0.66, 0.3), "muzzle": (-0.2086, 0.8934, 0.568)},
}
NAME = "birdeater"
PITCH = 34.0  # launcher elevation, degrees
PIVOT = (0.0, -0.3, 0.66)  # turret ring, on the hull roof


def _outline(hx, hy, c):
    """A rectangle with chamfered corners, counter-clockwise from above: 8 (x, y) points."""
    return [(-hx + c, -hy), (hx - c, -hy), (hx, -hy + c), (hx, hy - c),
            (hx - c, hy), (-hx + c, hy), (-hx, hy - c), (-hx, -hy + c)]


def _skirt():
    """The rubber skirt: an open band from a wide chamfered outline on the ground up to the hull's underside, so it
    flares out below the hull like an inflated apron. No top (the hull covers it), no floor: 16 triangles."""
    lo = [(x, y, 0.0) for x, y in _outline(1.22, 1.62, 0.36)]
    hi = [(x, y, 0.3) for x, y in _outline(0.95, 1.4, 0.06)]
    n = len(lo)
    faces = [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    return common.mesh("skirt", lo + hi, faces)


def _hex(r, y, zc):
    """Six points round (0, y, zc) in the XZ plane, flat side down, counter-clockwise seen from +Y."""
    pts = [(r * math.cos(math.radians(60 * k)), y, zc + r * math.sin(math.radians(60 * k))) for k in range(6)]
    return [(p[0], p[1], p[2]) for p in reversed(pts)]


def _fan():
    """The rear ducted fan on its deck: an open hexagonal team-coloured duct seen from inside and out (24), with a
    dark fan disc across its middle, a face each way (8)."""
    r, zc, y0, y1 = 0.5, 1.06, 0.78, 1.2
    duct = common.band("duct", r, y1 - y0, segments=6, thickness=0.09)
    duct.rotation_euler = (math.radians(90.0), 0.0, 0.0)
    duct.location = (0.0, (y0 + y1) / 2.0, zc)
    ym = (y0 + y1) / 2.0 + 0.06
    ring = _hex(r - 0.08, ym, zc)
    face = common.mesh("fan_face", ring + ring, [tuple(range(6)), tuple(reversed(range(6, 12)))])
    return duct, face


def generate(params):
    accent = params["color"]
    m = common.Materials(accent)
    objects = []

    # Skirt (the footprint object): 16.
    skirt = _skirt()
    common.paint(skirt, palette.RUBBER)
    objects.append(skirt)

    # Armoured hull with a sloped glacis and a raked stern, no floor: 14.
    hull = v.prism(
        "hull",
        [(-1.46, 0.3), (-0.86, 0.64), (1.22, 0.68), (1.42, 0.5), (1.42, 0.3)],
        width_bottom=1.9,
        width_top=1.5,
    )
    common.body_mat(hull)
    objects.append(hull)

    # A lit cockpit slit across the top of the glacis: 2.
    gy0, gz0, gy1, gz1 = -1.46, 0.3, -0.86, 0.64
    ny, nz = -(gz1 - gz0), gy1 - gy0
    nl = math.hypot(ny, nz)
    ny, nz = ny / nl * 0.01, nz / nl * 0.01

    def glacis(s):
        return gy0 + (gy1 - gy0) * s + ny, gz0 + (gz1 - gz0) * s + nz

    (ya, za), (yb, zb) = glacis(0.62), glacis(0.86)
    slit = common.mesh("slit", [(-0.42, ya, za), (0.42, ya, za), (0.36, yb, zb), (-0.36, yb, zb)], [(0, 1, 2, 3)])
    common.glow_mat(slit, palette.AMBER)
    objects.append(slit)

    # Rear ducted fan: 32.
    duct, face = _fan()
    common.accent_mat(duct, accent)
    common.trim_mat(face)
    objects += [duct, face]

    # Turret ring: a squat dark tapered block on the roof, no floor: 10.
    ring = common.block("ring", 0.78, 0.78, 0.16, top=(0.62, 0.62), drop=('bottom',))
    common.trim_mat(ring)
    ring = common.merge("ring_m", [ring], origin=PIVOT)
    objects.append(common.art_group(ring, "turret_1", pivot=True, kind="turret", weapon=1))

    # Missile box pitched up over the ring, its back sunk into the ring: 12 (10 accent + a dark mouth, 2).
    box, mouth = v.beam("launcher", 0.66, 0.44, 1.02, (0.0, 0.46, 0.2), pitch_deg=PITCH, drop=("front",))
    common.accent_mat(box, accent)
    objects.append(common.art_group(common.merge("launcher_m", [box], origin=PIVOT), "turret_1"))
    mouth_quad, _ = v.beam("mouth", 0.66, 0.44, 0.001, mouth, pitch_deg=PITCH, drop=("back", "top", "bottom", "left", "right"))
    common.trim_mat(mouth_quad)
    objects.append(common.art_group(common.merge("mouth_m", [mouth_quad], origin=PIVOT), "turret_1"))

    # Three missile noses in a row out of the mouth, pitched with the box: 12.
    noses = []
    for i, x in enumerate((-0.2, 0.0, 0.2)):
        n = v.spike(f"nose_{i}", 0.1, 0.22, (mouth[0] + x, mouth[1], mouth[2]))
        n.rotation_euler = (-math.radians(PITCH), 0.0, 0.0)
        noses.append(n)
    m.paint("body", *noses)
    objects.append(common.art_group(common.merge("noses_m", noses, origin=PIVOT), "turret_1"))

    return objects
