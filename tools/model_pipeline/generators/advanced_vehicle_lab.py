"""unit_defs/factory.luau `advanced_vehicle_lab` (BAR coravp): a factory for T2
vehicles.

The vehicle lab's wide bay walled in and roofed over: tall armoured side walls with a steep front glacis, a big
hangar across the back whose roof slopes down toward the door, and a team-coloured crane bridge spanning the
doorway high above the bay, from which two yellow nanolathes reach down and out over the front edge, where
production.luau builds each unit (Blender -Y, Roblox +Z). Under 100 triangles.
"""

from .shared import common
from .shared import factory as fc

CATEGORY = "entity"
DEF = "advanced_vehicle_lab"


def generate(params):
    hw, hl = params["collider"]["width"] / 2, params["collider"]["length"] / 2
    trim, body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    floor = 0.5
    bay = 3.6
    front = -5.9
    wall_top = 5.2
    glacis_top = -4.2

    footing = fc.Shape().hull((-hw, hw, -hl, hl), (-5.8, 5.8, -5.8, 5.8), 0.0, floor)

    for sx in (-1, 1):
        inner, outer, outer_top = sx * bay, sx * 6.0, sx * 5.2
        body.hull((min(inner, outer), max(inner, outer), front, 5.9),
                  (min(inner, outer_top), max(inner, outer_top), glacis_top, 5.9), floor, wall_top)
        # Team stripe down each glacis.
        n = fc.V((0.0, -(wall_top - floor), glacis_top - front)).normalized() * 0.03
        a, b = sx * 4.1, sx * 4.9
        accent.quad(fc.V((a, front, floor + 0.2)) + n, fc.V((b, front, floor + 0.2)) + n,
                    fc.V((b, glacis_top, wall_top)) + n, fc.V((a, glacis_top, wall_top)) + n, normal=n)
        r0, r1 = sx * (bay - 0.9), sx * (bay - 0.5)
        nano.quad((r0, front, floor + 0.02), (r1, front, floor + 0.02), (r1, 0.6, floor + 0.02), (r0, 0.6, floor + 0.02),
                  normal=(0, 0, 1))

    # Hangar across the back: its roof slopes from the back wall's top down to the bay.
    body.hull((-bay, bay, 0.6, 5.9), (-bay, bay, 3.4, 5.9), floor, 7.0, drop=("bottom", "left", "right"))
    # Crane bridge across the doorway, resting on the wall tops.
    accent.box(-5.6, 5.6, -4.1, -2.7, wall_top, 6.6)
    trim.box(-bay, bay, -3.95, -2.85, 4.5, wall_top, drop=("bottom", "left", "right", "top", "back"))
    for sx in (-1, 1):
        fc.nano_arm(nano, glow, [(sx * 1.7, -3.4, 5.9), (sx * 1.7, -3.9, 4.4)], (sx * 0.5, -8.6, 0.6),
                    w=0.5, reach=1.8, glow_len=0.7)
    fc.chevron(nano, 0.0, front - 0.1, floor + 0.02, 4.0, 0.7)

    objs = [
        common.trim_mat(footing.build("footing")),
        common.body_mat(body.build("body")),
        common.trim_mat(trim.build("trim")),
        common.accent_mat(accent.build("accent"), params["color"]),
        common.hivis_mat(nano.build("nano")),
        common.nano_mat(glow.build("glow")),
    ]
    return objs
