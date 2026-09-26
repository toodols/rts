"""unit_defs/t3.luau `juggernaut` (BAR corkorg): the enormous experimental assault walker.

Held to 100 triangles, so it is a
few big, strongly tapered blocks: two armoured column legs on sloped wedge feet, an inverted wedge of a chest
hunched forward at the shoulders with its reactor glowing through the front plate, a small head set low with a
glowing heat-ray visor, huge team-coloured arm blocks, a gauss cannon jutting forward from the right fist and a
rocket launcher box on the left.

Each leg (column and foot) is its own kind="leg" piece swinging fore and aft about its hip while it walks; everything from the waist up is one piece marked as weapon 1's turret
(the heat ray). Its weapons have no turret in the def, so for now it simply stays facing forward.
"""

import math

import mathutils

from .shared import air_t1 as air
from .shared import common
from .shared import palette
from .shared import t3 as t3

CATEGORY = "entity"
DEF = "juggernaut"
MOUNTS = {
    1: {"pivot": (0, 6.6005, -0.2611), "muzzle": (2.91, 1.6012, 4.1247)},
}
HIP_Z = 5.4
SWING = 0.22
STRIDE = round(4.0 * HIP_Z * math.sin(SWING), 2)


def generate(params):
    accent = params["color"]
    m = common.Materials(accent, palette.HEAT_ORANGE)
    upper = []

    # Chest first (the model is centred on it): an inverted wedge, narrow at the waist, broad and hunched
    # forward at the shoulders, with the reactor glowing through its front plate.
    chest = common.block("chest", 3.0, 2.2, 5.4, top=(4.6, 3.0), top_offset=(0.0, -0.2), origin=(0.0, 0.2, 5.4))
    common.drop_faces(chest, [0])
    m.body(chest)
    upper.append(chest)
    slope = mathutils.Vector((0.0, -0.6, 5.4)).normalized()
    reactor = air.plate("reactor", (0.0, -1.27, 8.4), (0.55, 0, 0), tuple(slope * 0.6),
                        (0.0, -slope.z, slope.y))
    m.glow(reactor)
    upper.append(reactor)

    # Head: a squat armoured block set low and forward between the shoulders, heat-ray visor across it.
    head = common.block("head", 1.6, 1.5, 1.4, top=(1.2, 1.4), origin=(0.0, -0.7, 10.5))
    common.drop_faces(head, [0])
    m.trim(head)
    upper.append(head)
    visor = air.plate("visor", (0.0, -1.47, 11.25), (0.52, 0, 0), (0, 0, 0.17), (0, -1, 0))
    m.glow(visor)
    upper.append(visor)

    # Arms: huge shoulder-to-fist blocks, broad at the pauldron, in the team colour.
    for side in (-1.0, 1.0):
        arm = common.block(f"arm_{side:+.0f}", 1.1, 1.3, 4.4, top=(1.9, 2.2), top_offset=(side * 0.15, -0.1), origin=(side * 2.9, 0.0, 6.6))
        common.drop_faces(arm, [0])
        m.accent(arm)
        upper.append(arm)

    # Gauss cannon out of the right fist, pointing forward, glowing at the muzzle.
    gun = air.beam("gauss", (2.9, 0.3, 6.95), (2.9, -2.95, 6.95), 1.05, 1.0, top_scale=0.6, open_start=True)
    common.drop_facing(gun, (0, 0, -1))
    m.trim(gun)
    upper.append(gun)
    muzzle = air.plate("gauss_muzzle", (2.9, -2.96, 6.95), (0.26, 0, 0), (0, 0, 0.24), (0, -1, 0))
    m.glow(muzzle)
    upper.append(muzzle)

    # Rocket launcher on the left fist: a fat box of tubes pointing forward, glowing out of its face.
    rack = air.beam("rocket_pod", (-2.9, 0.3, 7.0), (-2.9, -2.3, 7.0), 1.5, 1.35, top_scale=0.9, open_start=True)
    common.drop_facing(rack, (0, 0, -1))
    m.trim(rack)
    upper.append(rack)
    tubes = air.plate("rocket_tubes", (-2.9, -2.31, 7.0), (0.52, 0, 0), (0, 0, 0.44), (0, -1, 0))
    m.glow(tubes)
    upper.append(tubes)

    for obj in upper:
        common.art_group(obj, "torso")
    common.art_group(chest, "torso", pivot=True, kind="turret", weapon=1)
    objects = list(upper)

    # Legs: armoured columns, thick at the thigh and narrowing to the ankle, on sloped wedge feet. Each leg is
    # its own walking piece swinging fore and aft about its hip, inside the chest's base.
    for side, group, phase in ((1.0, "leg_l", 0.0), (-1.0, "leg_r", 0.5)):
        leg = common.block(f"leg_{side:+.0f}", 1.2, 1.4, 4.9, top=(1.8, 2.0), top_offset=(-side * 0.1, 0.1), origin=(side * 1.35, 0.0, 0.9))
        common.drop_faces(leg, [0, 1])  # its ends are inside the foot and the chest
        foot = t3.wedge(f"foot_{side:+.0f}", 1.9, 3.0, 1.2, 0.6, origin=(side * 1.4, -0.5, 0.0), ridge_x=1.5)
        hip = (side * 1.3, 0.1, HIP_Z)
        objects.append(t3.leg_piece(f"leg_{side:+.0f}", [leg, foot], hip, m.body, group,
                                    axis=(1.0, 0.0, 0.0), swing=SWING, phase=phase, stride=STRIDE))

    return objects
