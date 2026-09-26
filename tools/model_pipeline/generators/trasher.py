"""unit_defs/bot_t1.luau `trasher` (corcrash): Cortex's amphibious anti-air bot.

A broad, squat, sealed hull on sturdy wading legs, with a tall missile rack on each shoulder pitched
steeply up and forward, their warheads bright at the tips so it reads as "shoots at the sky" from
above. A small sensor head sits between the racks. The upper body turns as weapon 1's turret; each leg swings about its hip as it walks.

Budget: 100 triangles.
"""

import math

from .shared import bot_t1 as bt
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "trasher"
MOUNTS = {
    1: {"pivot": (0, 0, 0), "muzzle": (-1.207, 2.7342, 0.9331)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent, palette.SEEKER_BLUE)

    upper = []
    hull = m.body(bt.slab("hull", 0.74, 0.6, 0.6, top_w=0.9, top_d=0.66, origin=(0.0, 0.0, 0.98)))
    upper.append(hull)
    upper.append(m.body(bt.slab("head", 0.34, 0.32, 0.22, top_w=0.26, top_d=0.24, top_offset=(0.0, 0.03), origin=(0.0, -0.14, 1.58))))
    upper.append(m.glow(bt.visor("visor", 0.0, -0.305, 1.68, 0.26, 0.07, lean=0.012)))

    # missile racks: steep boxes out on each shoulder, pitched 35 degrees off vertical toward the front
    tilt = math.radians(42.0)
    length = 0.82
    for side in (-1.0, 1.0):
        x = side * 0.58
        base = (x, 0.26, 1.2)
        top = (x, base[1] - length * math.sin(tilt), base[2] + length * math.cos(tilt))
        rack = m.accent(bt.beam(f"rack_{side}", base, top, 0.32, 0.4, 0.3, 0.36, caps="b"))
        upper.append(rack)
        # warheads: two points poking out of the rack's open top
        tops = [rack.data.vertices[i].co for i in range(4, 8)]
        cx = sum(v.x for v in tops) / 4.0
        cy = sum(v.y for v in tops) / 4.0
        cz = sum(v.z for v in tops) / 4.0
        upper.append(m.trim(bt.quad(f"rack_top_{side}", [tuple(v) for v in tops])))
        axis = (0.0, -math.sin(tilt), math.cos(tilt))
        # a 2 x 2 cluster; `across` runs over the top face at right angles to the X axis
        across = (0.0, math.cos(tilt), math.sin(tilt))
        for k in (-1.0, 1.0):
            for j in (-1.0, 1.0):
                c = (cx + k * 0.075, cy + across[1] * j * 0.09, cz + across[2] * j * 0.09)
                tip = (c[0] + axis[0] * 0.18, c[1] + axis[1] * 0.18, c[2] + axis[2] * 0.18)
                upper.append(m.body(bt.pyramid(f"warhead_{side}_{k}_{j}", c, 0.12, 0.13, tip)))

    # each leg is one rigid piece swinging about its hip while the unit walks, the two half a cycle apart
    legs = []
    for name, side, phase in (("leg_l", -1.0, 0.0), ("leg_r", 1.0, 0.5)):
        hip = (side * 0.34, 0.0, 1.02)
        parts = [bt.pillar_leg(name, hip, (side * 0.46, 0.0), 0.3, 0.36, 0.4, 0.56)]
        legs.append(bt.walking_leg(name, parts, hip, m.trim, phase, 0.32))

    bt.group(upper, "torso", hull, kind="turret", weapon=1)
    objs = upper + legs
    return objs
