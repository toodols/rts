"""unit_defs/factory.luau `advanced_bot_lab` (BAR coralab): a 3x2x3 cell (12 x 8 x 12 stud) factory for T2 bots.

The bot lab's layout grown heavier on the same footprint: taller shoulders with a steeper glacis, each carrying a
massive team-coloured armour block, a dark bridge across the top of the doorway with two yellow nanolathes
hanging from it and aimed out over the front lip, where production.luau builds each unit (Blender -Y,
Roblox +Z), and a tall command tower at the back. Under 100 triangles.
"""

from . import factory_common as fc


def generate(params):
    k = fc.Kit("advbotlab")
    trim, body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    floor = 0.6
    bay = 2.4
    front = -5.8
    sh_top = 5.0
    glacis_top = -3.6

    footing = fc.Shape().hull((-6, 6, -6, 6), (-5.6, 5.6, -5.6, 5.6), 0.0, floor)

    for sx in (-1, 1):
        inner, outer, outer_top = sx * bay, sx * 5.8, sx * 5.0
        body.hull((min(inner, outer), max(inner, outer), front, 5.8),
                  (min(inner, outer_top), max(inner, outer_top), glacis_top, 5.8), floor, sh_top)
        # Armour block on top, sloped at the front and outside, in the team colour.
        a0, a1, t1 = sx * (bay - 0.2), sx * 4.9, sx * 4.2
        accent.hull((min(a0, a1), max(a0, a1), glacis_top + 0.2, 5.6), (min(a0, t1), max(a0, t1), glacis_top + 1.6, 5.2),
                    sh_top, sh_top + 1.7)

    # Command tower at the back, taller than the armour.
    body.hull((-bay + 0.2, bay - 0.2, 2.6, 5.8), (-bay + 0.6, bay - 0.6, 3.8, 5.4), floor, 7.9)
    # Roof over the bay, buried in the shoulders and the tower.
    trim.hull((-bay, bay, -3.0, 3.2), (-bay, bay, -2.6, 3.2), 3.9, 4.7, drop=("left", "right", "back", "bottom"))
    # Bridge over the doorway, its ends buried in the armour blocks.
    trim.box(-3.6, 3.6, -3.9, -2.5, 5.4, 6.3, drop=("left", "right"))
    for sx in (-1, 1):
        fc.nano_arm(nano, glow, [(sx * 1.3, -3.2, 5.9)], (sx * 0.4, -8.3, 0.8), w=0.5, reach=2.5, glow_len=0.75)
    fc.chevron(nano, 0.0, front - 0.1, floor + 0.02, 3.4, 0.6)

    objs = [
        k.trim(footing.build("footing")),
        k.body(body.build("body")),
        k.trim(trim.build("trim")),
        k.accent(accent.build("accent")),
        k.nano(nano.build("nano")),
        k.glow(glow.build("glow")),
    ]
    return fc.finish(objs)
