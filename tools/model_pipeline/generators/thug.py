"""unit_defs/bot_t1.luau `thug` (corthud): Cortex's sturdy light plasma bot.

Short, wide and heavily plated where the Grunt is a slim runner: stubby braced legs, a broad torso
with an armored hump on top, the head sunk low at the front, massive shoulder plates, a fat plasma
cannon on the right arm and an armored fist on the left. The upper body turns as weapon 1's turret; each leg swings about its hip as it walks.

Budget: 100 triangles.
"""

from .shared import bot_t1 as bt
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "thug"
MOUNTS = {
    1: {"pivot": (0, 0, 0), "muzzle": (1.0606, 2.0823, 1.3182)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent, palette.PLASMA_GOLD)

    upper = []
    chest = m.body(bt.slab("chest", 0.72, 0.56, 0.66, top_w=1.0, top_d=0.74, top_offset=(0.0, 0.0), origin=(0.0, 0.0, 1.10)))
    upper.append(chest)
    upper.append(m.accent(bt.slab("hump", 0.92, 0.66, 0.14, top_w=0.66, top_d=0.44, top_offset=(0.0, 0.04), origin=(0.0, 0.0, 1.76))))
    upper.append(m.trim(bt.slab("head", 0.38, 0.3, 0.2, top_w=0.3, top_d=0.22, top_offset=(0.0, 0.03), origin=(0.0, -0.33, 1.70))))
    upper.append(m.glow(bt.visor("visor", 0.0, -0.485, 1.79, 0.3, 0.07, lean=0.01)))
    for side in (-1.0, 1.0):
        upper.append(m.accent(bt.slab(f"pad_{side}", 0.42, 0.6, 0.3, top_w=0.28, top_d=0.44, top_offset=(side * 0.05, 0.0), origin=(side * 0.66, 0.0, 1.58))))
    # left: an armored fist, a block hanging from the pad
    upper.append(m.trim(bt.slab("fist_l", 0.26, 0.34, 0.5, top_w=0.22, top_d=0.3, top_offset=(0.0, 0.06), origin=(-0.7, -0.12, 1.10))))
    # right: the plasma cannon, a heavy breech tapering to the muzzle
    cx, cz = 0.7, 1.36
    upper.append(m.trim(bt.beam("cannon", (cx, 0.14, cz), (cx, -0.9, cz), 0.3, 0.36, 0.2, 0.22, caps="tb")))
    upper.append(m.glow(bt.pyramid("muzzle", (cx, -0.9, cz), 0.16, 0.18, (cx, -0.98, cz))))

    # each leg is one rigid piece swinging about its hip while the unit walks, the two half a cycle apart;
    # a heavy bot, so a short swing
    legs = []
    for name, side, phase in (("leg_l", -1.0, 0.0), ("leg_r", 1.0, 0.5)):
        hip = (side * 0.36, 0.0, 1.14)
        parts = [bt.pillar_leg(name, hip, (side * 0.5, -0.02), 0.3, 0.34, 0.38, 0.54)]
        legs.append(bt.walking_leg(name, parts, hip, m.body, phase, 0.3))

    bt.group(upper, "torso", chest, kind="turret", weapon=1)
    objs = upper + legs
    return objs
