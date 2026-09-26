"""unit_defs/factory.luau `air_lab` (BAR corap): an aircraft factory.

A flat apron with a team-coloured hexagonal landing pad marked with a yellow H, a low hangar with a raked front
across the back, and two sloped nanolathe blocks on the front corners whose arms lean in over the front edge,
where production.luau builds each aircraft (Blender -Y, Roblox +Z). A radar paddle on a mast at the hangar's
corner spins (common.art_group kind="spin"), poking a little above the 4-stud box. Under 100 triangles.
"""

import math

from .shared import common
from .shared import factory as fc

CATEGORY = "entity"
DEF = "air_lab"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"height": 5.0}


def generate(params):
    hw, hl = params["collider"]["width"] / 2, params["collider"]["length"] / 2
    trim, body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    floor = 0.12

    # A flat tarmac apron, only its top: its edges are too thin to see.
    footing = fc.Shape().quad((-hw, -hl, floor), (hw, -hl, floor), (hw, hl, floor), (-hw, hl, floor), normal=(0, 0, 1))

    # Landing pad: a flat hexagon in the team colour with a yellow H.
    cy, z = -0.9, floor + 0.02
    r = 3.5
    hexagon = [(r * math.cos(math.pi / 6 + i * math.pi / 3), cy + r * math.sin(math.pi / 6 + i * math.pi / 3), z) for i in range(6)]
    i = accent._add(hexagon)
    accent._face([i + j for j in range(6)], normal=(0, 0, 1))
    z2 = z + 0.02
    for x in (-1.1, 0.7):
        nano.quad((x, cy - 1.4, z2), (x + 0.4, cy - 1.4, z2), (x + 0.4, cy + 1.4, z2), (x, cy + 1.4, z2), normal=(0, 0, 1))
    nano.quad((-0.7, cy - 0.2, z2), (0.7, cy - 0.2, z2), (0.7, cy + 0.2, z2), (-0.7, cy + 0.2, z2), normal=(0, 0, 1))

    # Hangar across the back, its front raked.
    hangar_top = 3.0
    body.hull((-5.8, 5.8, 3.3, 5.8), (-5.4, 5.4, 4.3, 5.6), floor, hangar_top)

    # Nanolathe blocks on the front corners, sloped toward the pad, each with an arm leaning in.
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 4.3, sx * 5.8))
        t0, t1 = sorted((sx * 4.9, sx * 5.6))
        body.hull((x0, x1, -5.8, -1.6), (t0, t1, -5.0, -2.4), floor, 2.0)
        fc.nano_arm(nano, glow, [(sx * 5.25, -3.4, 1.6), (sx * 4.9, -4.2, 3.4)], (sx * 0.8, -8.6, 0.8),
                    w=0.5, reach=1.9, glow_len=0.65)

    # Radar mast at the hangar's corner, and the paddle that spins on it.
    mx, my = 4.3, 4.9
    mast_top = 4.4
    trim.path([(mx, my, hangar_top - 0.2), (mx, my, mast_top)], 0.3)
    paddle = fc.Shape().hull((-0.35, 0.35, -0.12, 0.12), (-1.2, 1.2, -0.2, 0.3), 0.0, 0.6)
    radar = common.trim_mat(paddle.build("radar"))
    radar.location = (mx, my, mast_top)

    objs = [
        common.trim_mat(footing.build("footing")),
        common.body_mat(body.build("body")),
        common.trim_mat(trim.build("trim")),
        common.accent_mat(accent.build("accent"), params["color"]),
        common.hivis_mat(nano.build("nano")),
        common.nano_mat(glow.build("glow")),
        common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=1.5),
    ]
    return objs
