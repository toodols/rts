"""unit_defs/factory.luau `bot_lab` (BAR corlab): a factory for T1 bots.

Two armoured shoulder blocks with sloped outer walls and front glacis flank an open bay under a roofed lintel; a
taller machine hall closes the back. Two yellow nanolathe arms rise from the shoulders' front corners and lean
out over the front lip, where production.luau builds each unit (Blender -Y, Roblox +Z). Under 100 triangles.
"""

from .shared import common
from .shared import factory as fc

CATEGORY = "entity"
DEF = "bot_lab"


def generate(params):
    hw, hl = params["collider"]["width"] / 2, params["collider"]["length"] / 2
    trim, body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    floor = 0.5
    bay = 2.6
    front = -5.6
    sh_top = 4.9
    glacis_top = -3.3

    footing = fc.Shape().hull((-hw, hw, -hl, hl), (-5.7, 5.7, -5.7, 5.7), 0.0, floor)

    for sx in (-1, 1):
        inner, outer, outer_top = sx * bay, sx * 5.6, sx * 4.8
        body.hull((min(inner, outer), max(inner, outer), front, 5.6),
                  (min(inner, outer_top), max(inner, outer_top), glacis_top, 5.6), floor, sh_top)
        # Team stripe down the glacis and a team panel on the shoulder roof.
        n = fc.V((0.0, -(sh_top - floor), glacis_top - front)).normalized() * 0.03
        a, b = sx * 3.5, sx * 4.3
        accent.quad(fc.V((a, front, floor + 0.3)) + n, fc.V((b, front, floor + 0.3)) + n,
                    fc.V((b, glacis_top, sh_top)) + n, fc.V((a, glacis_top, sh_top)) + n, normal=n)
        accent.quad((sx * 3.0, -1.0, sh_top + 0.03), (sx * 4.4, -1.0, sh_top + 0.03),
                    (sx * 4.4, 5.0, sh_top + 0.03), (sx * 3.0, 5.0, sh_top + 0.03), normal=(0, 0, 1))
        # Nanolathe arm on the shoulder's front corner, leaning out over the lip at the build spot.
        fc.nano_arm(nano, glow, [(sx * 3.7, glacis_top + 1.2, sh_top - 0.3), (sx * 3.5, glacis_top + 0.5, sh_top + 1.9)],
                    (sx * 0.8, -8.5, 0.8), w=0.45, reach=2.3, glow_len=0.7)

    # Machine hall across the back, its front sloped back, taller than the shoulders.
    body.hull((-bay, bay, 2.4, 5.6), (-bay, bay, 3.6, 5.6), floor, 6.6)
    # Roof over the bay, its front edge the doorway's lintel; its ends and back are buried.
    trim.hull((-bay, bay, -3.5, 3.0), (-bay, bay, -3.0, 3.0), 3.7, 4.6, drop=("left", "right", "back"))
    fc.chevron(nano, 0.0, front - 0.2, floor + 0.02, 3.6, 0.6)

    objs = [
        common.trim_mat(footing.build("footing")),
        common.body_mat(body.build("body")),
        common.trim_mat(trim.build("trim")),
        common.accent_mat(accent.build("accent"), params["color"]),
        common.hivis_mat(nano.build("nano")),
        common.nano_mat(glow.build("glow")),
    ]
    return objs
