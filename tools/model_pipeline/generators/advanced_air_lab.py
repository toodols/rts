"""unit_defs/factory.luau `advanced_air_lab`: a 3x2x3 cell (12 x 8 x 12 stud) factory for T2 aircraft.

The Air Lab grown up: the same open apron and team-coloured hexagonal pad at the front, where production.luau builds
each aircraft (Blender -Y, Roblox +Z), but a tall hangar across the back with a roof raked down toward the pad, a
control tower on one back corner with a spinning radar paddle on top, and two tall armoured nanolathe pylons on the
front corners whose arms lean far in over the pad. Under 100 triangles.
"""

import math

from . import common
from . import factory_common as fc


def generate(params):
    k = fc.Kit("advairlab")
    trim, body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    floor = 0.12

    # A flat apron, only its top.
    footing = fc.Shape().quad((-6, -6, floor), (6, -6, floor), (6, 6, floor), (-6, 6, floor), normal=(0, 0, 1))

    # Landing pad: a team-coloured hexagon with a yellow bar across it.
    cy, z = -1.4, floor + 0.02
    r = 3.3
    hexagon = [(r * math.cos(math.pi / 6 + i * math.pi / 3), cy + r * math.sin(math.pi / 6 + i * math.pi / 3), z)
               for i in range(6)]
    i = accent._add(hexagon)
    accent._face([i + j for j in range(6)], normal=(0, 0, 1))
    nano.quad((-1.6, cy - 0.25, z + 0.02), (1.6, cy - 0.25, z + 0.02), (1.6, cy + 0.25, z + 0.02),
              (-1.6, cy + 0.25, z + 0.02), normal=(0, 0, 1))

    # Tall hangar across the back, its roof raked down toward the pad.
    body.hull((-5.8, 5.8, 2.2, 5.8), (-5.8, 5.8, 4.2, 5.8), floor, 6.2, drop=("bottom",))
    # The doorway: a dark face on the hangar's front.
    trim.quad((-3.6, 2.19, floor + 0.05), (3.6, 2.19, floor + 0.05), (3.6, 2.8, floor + 3.0), (-3.6, 2.8, floor + 3.0),
              normal=(0, -1, 0.3))

    # Control tower on the back left corner, standing proud of the hangar, glazed near the top.
    tx, ty = -4.6, 4.6
    trim.hull((tx - 1.0, tx + 1.0, ty - 1.0, ty + 1.0), (tx - 0.8, tx + 0.8, ty - 0.8, ty + 0.8), 6.0, 7.4,
              drop=("bottom",))
    radar_z = 7.4

    # Nanolathe pylons on the front corners, sloped in, each with an arm leaning over the pad.
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 4.5, sx * 5.9))
        t0, t1 = sorted((sx * 4.9, sx * 5.6))
        body.hull((x0, x1, -5.9, -2.0), (t0, t1, -5.1, -2.7), floor, 3.6)
        fc.nano_arm(nano, glow, [(sx * 5.25, -3.6, 3.2), (sx * 4.9, -4.4, 5.4)], (sx * 0.8, -8.6, 0.8),
                    w=0.55, reach=2.0, glow_len=0.7)

    paddle = fc.Shape().hull((-0.35, 0.35, -0.12, 0.12), (-1.1, 1.1, -0.2, 0.3), 0.0, 0.5)
    radar = k.accent(paddle.build("radar"))
    radar.location = (tx, ty, radar_z)

    objs = [
        k.trim(footing.build("footing")),
        k.body(body.build("body")),
        k.trim(trim.build("trim")),
        k.accent(accent.build("accent")),
        k.nano(nano.build("nano")),
        k.glow(glow.build("glow")),
        common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=1.5),
    ]
    return fc.finish(objs)
