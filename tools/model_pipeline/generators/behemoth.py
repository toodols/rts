"""unit_defs/t3.luau `behemoth` (BAR corjugg): Cortex's experimental heavy assault walker.

Held to 100 triangles. After BAR's
model: a squat armoured box of a body on four short, stout legs, each under a great team-coloured armour block, with
a domed turret on top that carries the gauss cannon along its crown, a glowing red sight across the dome's face, and
two lasers slung low on the front of the body.

Each leg (armour block and shin) is its own kind="leg" piece swinging fore and aft about its hip while it walks, the
diagonal pairs together; the dome, its gun and its sight are one piece following weapon 1's aim (the gauss cannon's
turret).
"""

import math

from .shared import air_t1 as air
from .shared import common
from .shared import palette
from .shared import t3 as t3

CATEGORY = "entity"
DEF = "behemoth"
MOUNTS = {
    1: {"pivot": (0, 5.3501, -0.3095), "muzzle": (-0.2657, 1.5326, 4.4004)},
}
HIP_Z = 3.6
SWING = 0.16
STRIDE = round(4.0 * HIP_Z * math.sin(SWING), 2)


def generate(params):
    accent = params["color"]
    m = common.Materials(accent, palette.HEAT_ORANGE)
    objects = []

    # Body first (the model is centred on it): a tapered box standing on its legs, without its underside (10 tris).
    body_z = 2.2
    body = common.drop_bottom(common.block("body", 3.2, 3.8, 2.6, top=(2.7, 3.2), top_offset=(0.0, 0.15), origin=(0.0, 0.0, body_z)))
    m.body(body)
    objects.append(body)

    # Two lasers slung low on the front, each a four-sided spike pointing ahead (4 tris each).
    for side in (-1.0, 1.0):
        x = side * 0.95
        y = -1.85
        z = body_z + 0.45
        laser = air.tetra(f"laser_{side:+.0f}", (x - 0.22, y + 0.3, z - 0.2), (x + 0.22, y + 0.3, z - 0.2),
                          (x, y + 0.3, z + 0.25), (x, y - 0.75, z))
        m.trim(laser)
        objects.append(laser)

    # Four legs on the corners: a great armour block over the hip, with neither underside nor the face against the
    # body (8 tris), and a stout three-sided shin down to the ground, open at both ends (6 tris). The model faces -Y,
    # so its left is +X: front-left and back-right step together, then front-right and back-left.
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            hip = (sx * 2.15, sy * 1.25, HIP_Z)
            pad = common.block(f"pad_{sx:+.0f}{sy:+.0f}", 1.25, 1.55, 1.75, top=(1.05, 1.35), top_offset=(sx * 0.05, 0.0), origin=(sx * 2.2, sy * 1.3, 2.35))
            # tapered_box's faces: 0 bottom, 1 top, then the sides; the side against the body is the one facing -sx
            inner = 5 if sx > 0 else 3
            common.drop_faces(pad, sorted([0, inner], reverse=True))
            shin = t3.tube(f"shin_{sx:+.0f}{sy:+.0f}", (sx * 2.25, sy * 1.35, 2.5), (sx * 2.4, sy * 1.5, 0.1), 0.62,
                           sides=3, radius2=0.8, open_start=True, open_end=True, up=(sx, sy, 0.0))
            front = "front" if sy < 0 else "back"
            left = "left" if sx > 0 else "right"
            phase = 0.0 if (sx > 0) == (sy < 0) else 0.5
            m.accent(pad)
            objects.append(common.art_group(pad, f"leg_{front}_{left}"))
            leg = t3.leg_piece(f"leg_{front}_{left}", [shin], hip, m.trim, f"leg_{front}_{left}",
                               axis=(1.0, 0.0, 0.0), swing=SWING, phase=phase, stride=STRIDE)
            objects.append(leg)

    # The dome: a five-sided frustum on the roof with its crown capped (13 tris), a red sight across its face (2),
    # and the gauss cannon along its crown, jutting far ahead (9 tris without its buried back end).
    top = body_z + 2.6
    pivot = (0.0, 0.25, top)
    px, py, pz = pivot
    dome = t3.tube("dome", pivot, (px, py, pz + 1.3), 1.45, sides=5, radius2=0.85, open_start=True, roll=math.pi / 2)
    m.body(dome)
    # the turret swivels about its origin, so the dome's is moved onto the swivel point
    for vert in dome.data.vertices:
        vert.co.x -= px
        vert.co.y -= py
        vert.co.z -= pz
    dome.location = pivot
    sight = air.plate("sight", (px, py - 1.22, pz + 0.75), (0.5, 0, 0), (0, 0.07, 0.12), (0, -1, 0.35))
    m.glow(sight, palette.SIGHT_RED)
    gun = air.beam("gauss", (px, py + 0.3, pz + 1.45), (px, py - 3.55, pz + 1.55), 0.55, 0.5, top_scale=0.7,
                   open_start=True)
    common.drop_facing(gun, (0, 0, -1), threshold=0.7)
    m.trim(gun)
    for obj in (dome, sight, gun):
        objects.append(common.art_group(obj, "turret"))
    common.art_group(dome, "turret", pivot=True, kind="turret", weapon=1)

    return objects
