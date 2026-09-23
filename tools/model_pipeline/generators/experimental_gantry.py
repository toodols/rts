"""unit_defs/factory.luau `experimental_gantry` (BAR corgant): a 4x3x4 cell (16 x 12 x 16 stud) factory for T3
experimentals.

Two massive sloped towers flank a tall open bay closed at the back by a dark wall; a heavy team-coloured gantry
bridge spans the tower tops over the doorway, and three yellow nanolathes hang from it, aimed down and out over
the front edge where production.luau builds each unit (Blender -Y, Roblox +Z). Under 100 triangles.
"""

from . import factory_common as fc


def generate(params):
    k = fc.Kit("gantry")
    trim, body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    floor = 0.7
    bay = 4.3
    front = -7.8
    tower_top = 11.8
    glacis_top = -5.0

    footing = fc.Shape().hull((-8, 8, -8, 8), (-7.6, 7.6, -7.6, 7.6), 0.0, floor)

    lean = 1.8  # the towers' inner walls lean in, narrowing the doorway toward the top
    for sx in (-1, 1):
        inner, inner_top, outer, outer_top = sx * bay, sx * (bay - lean), sx * 8.0, sx * 6.6
        body.hull((min(inner, outer), max(inner, outer), front, 7.8),
                  (min(inner_top, outer_top), max(inner_top, outer_top), glacis_top, 6.6), floor, tower_top)
        # Team stripe up each glacis.
        n = fc.V((0.0, -(tower_top - floor), glacis_top - front)).normalized() * 0.04
        a, b = sx * 5.2, sx * 6.2
        accent.quad(fc.V((a, front, floor + 0.3)) + n, fc.V((b, front, floor + 0.3)) + n,
                    fc.V((b, glacis_top, tower_top)) + n, fc.V((a, glacis_top, tower_top)) + n, normal=n)
    # Back wall between the towers, buried in them.
    wall_top = 9.6
    wt = bay - lean * (wall_top - floor) / (tower_top - floor)
    trim.hull((-bay, bay, 4.4, 7.6), (-wt, wt, 5.4, 7.6), floor, wall_top, drop=("bottom", "left", "right"))
    # A glowing slot down the back wall, the gantry's reactor.
    n = fc.V((0.0, -(wall_top - floor), 1.0)).normalized() * 0.04
    glow.quad(fc.V((-0.5, 4.5, floor + 0.8)) + n, fc.V((0.5, 4.5, floor + 0.8)) + n,
              fc.V((0.5, 5.3, wall_top - 0.8)) + n, fc.V((-0.5, 5.3, wall_top - 0.8)) + n, normal=n)
    # Gantry bridge between the tower tops over the doorway, its ends buried in the towers.
    accent.box(-5.0, 5.0, -5.2, -2.8, 9.0, 10.6, drop=("left", "right"))
    for sx in (-1, 1):
        a, b = sx * (bay - lean + 0.3), sx * 6.3
        accent.quad((a, glacis_top + 0.3, tower_top + 0.03), (b, glacis_top + 0.3, tower_top + 0.03),
                    (b, 6.3, tower_top + 0.03), (a, 6.3, tower_top + 0.03), normal=(0, 0, 1))
    for x in (-2.4, 0.0, 2.4):
        fc.nano_arm(nano, glow, [(x, -4.1, 9.4)], (x * 0.3, -11.0, 1.0), w=0.65, reach=3.2, glow_len=0.9)
    fc.chevron(nano, 0.0, front - 0.1, floor + 0.02, 5.6, 0.9)
    fc.chevron(nano, 0.0, front + 2.2, floor + 0.02, 5.6, 0.9)

    objs = [
        k.trim(footing.build("footing")),
        k.body(body.build("body")),
        k.trim(trim.build("trim")),
        k.accent(accent.build("accent")),
        k.nano(nano.build("nano")),
        k.glow(glow.build("glow")),
    ]
    return fc.finish(objs)
