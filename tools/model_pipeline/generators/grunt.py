"""unit_defs/bot_t1.luau `grunt` (corak): Cortex's fast light infantry bot with a laser rifle.

A slim, long-legged runner caught mid-stride: a chest that is narrow at the waist and broad at the
shoulders, a helmeted head low and forward with a glowing visor, big red shoulder pads, and a long
laser rifle slung under the right pad. The upper body turns as weapon 1's turret; each leg swings about its hip as it walks.

Budget: 100 triangles.
"""

from .shared import bot_t1 as bt
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "grunt"
MOUNTS = {
    1: {"pivot": (0, 0, 0), "muzzle": (0.8416, 2.0618, 1.0909)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent, palette.LASER_ORANGE)

    upper = []
    # chest first: it is the footprint build.py centres the model on
    chest = m.body(bt.slab("chest", 0.46, 0.38, 0.62, top_w=0.8, top_d=0.56, origin=(0.0, 0.0, 1.24)))
    upper.append(chest)
    upper.append(m.body(bt.slab("head", 0.32, 0.34, 0.26, top_w=0.22, top_d=0.24, top_offset=(0.0, 0.04), origin=(0.0, -0.2, 1.8))))
    upper.append(m.glow(bt.visor("visor", 0.0, -0.375, 1.93, 0.28, 0.07, lean=0.015)))
    for side in (-1.0, 1.0):
        upper.append(m.accent(bt.slab(f"pad_{side}", 0.3, 0.46, 0.24, top_w=0.2, top_d=0.34, top_offset=(-side * 0.04, 0.0), origin=(side * 0.52, 0.0, 1.68))))
    # the rifle: deep at the back where it hangs from the shoulder, thin at the muzzle
    gx = 0.52
    upper.append(m.trim(bt.beam("rifle", (gx, 0.16, 1.52), (gx, -0.84, 1.46), 0.17, 0.3, 0.12, 0.13, caps="tb")))
    upper.append(m.glow(bt.pyramid("muzzle", (gx, -0.84, 1.46), 0.14, 0.15, (gx, -0.91, 1.46))))

    # each leg is one rigid piece swinging about its hip while the unit walks, the two half a cycle apart
    legs = []
    for name, side, phase in (("leg_l", -1.0, 0.0), ("leg_r", 1.0, 0.5)):
        hip = (side * 0.28, 0.0, 1.3)
        parts = bt.leg(m, name, hip, (side * 0.33, -0.16, 0.72), (side * 0.33, -0.04), 0.26, 0.56, 0.24, 0.2)
        legs.append(bt.walking_leg(name, parts, hip, m.trim, phase, 0.4))

    bt.group(upper, "torso", chest, kind="turret", weapon=1)
    objs = upper + legs
    return objs
