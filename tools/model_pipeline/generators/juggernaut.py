"""unit_defs/t3.luau `juggernaut` (BAR corkorg): the enormous experimental assault walker.

Collider capsule(97, 160, 85): radius 97/22 = 4.41 studs, height 160/11 = 14.5. Held to 100 triangles, so it is a
few big, strongly tapered blocks: two armoured column legs on sloped wedge feet, an inverted wedge of a chest
hunched forward at the shoulders with its reactor glowing through the front plate, a small head set low with a
glowing heat-ray visor, huge team-coloured arm blocks, a gauss cannon jutting forward from the right fist and a
rocket launcher box on the left.

Each leg (column and foot) is its own kind="leg" piece swinging fore and aft about its hip while it walks; everything from the waist up is one piece marked as weapon 1's turret
(the heat ray). Its weapons have no turret in the def, so for now it simply stays facing forward.
"""

import math

import mathutils

from . import air_t1_common as air
from . import common
from . import t3_common as t3

ACCENT = air.rgb(198, 86, 72)
RADIUS, HEIGHT = 97 / 22, 160 / 11
DEF = "juggernaut"
HIP_Z = 5.4
SWING = 0.22
STRIDE = round(4.0 * HIP_Z * math.sin(SWING), 2)


def generate(params):
    upper = []

    # Chest first (the model is centred on it): an inverted wedge, narrow at the waist, broad and hunched
    # forward at the shoulders, with the reactor glowing through its front plate.
    chest = air.block("chest", 3.0, 2.2, 5.4, 4.6, 3.0, top_offset=(0.0, -0.2), origin=(0.0, 0.2, 5.4))
    air.drop_faces(chest, [0])
    t3.mat(chest, "body")
    upper.append(chest)
    slope = mathutils.Vector((0.0, -0.6, 5.4)).normalized()
    reactor = air.plate("reactor", (0.0, -1.27, 8.4), (0.55, 0, 0), tuple(slope * 0.6),
                        (0.0, -slope.z, slope.y))
    t3.mat(reactor, "glow")
    upper.append(reactor)

    # Head: a squat armoured block set low and forward between the shoulders, heat-ray visor across it.
    head = air.block("head", 1.6, 1.5, 1.4, 1.2, 1.4, origin=(0.0, -0.7, 10.5))
    air.drop_faces(head, [0])
    t3.mat(head, "trim")
    upper.append(head)
    visor = air.plate("visor", (0.0, -1.47, 11.25), (0.52, 0, 0), (0, 0, 0.17), (0, -1, 0))
    t3.mat(visor, "glow")
    upper.append(visor)

    # Arms: huge shoulder-to-fist blocks, broad at the pauldron, in the team colour.
    for side in (-1.0, 1.0):
        arm = air.block(f"arm_{side:+.0f}", 1.1, 1.3, 4.4, 1.9, 2.2, top_offset=(side * 0.15, -0.1),
                        origin=(side * 2.9, 0.0, 6.6))
        air.drop_faces(arm, [0])
        t3.mat(arm, "accent", DEF, ACCENT)
        upper.append(arm)

    # Gauss cannon out of the right fist, pointing forward, glowing at the muzzle.
    gun = air.beam("gauss", (2.9, 0.3, 6.95), (2.9, -2.95, 6.95), 1.05, 1.0, top_scale=0.6, open_start=True)
    t3.drop_facing(gun, (0, 0, -1))
    t3.mat(gun, "trim")
    upper.append(gun)
    muzzle = air.plate("gauss_muzzle", (2.9, -2.96, 6.95), (0.26, 0, 0), (0, 0, 0.24), (0, -1, 0))
    t3.mat(muzzle, "glow")
    upper.append(muzzle)

    # Rocket launcher on the left fist: a fat box of tubes pointing forward, glowing out of its face.
    rack = air.beam("rocket_pod", (-2.9, 0.3, 7.0), (-2.9, -2.3, 7.0), 1.5, 1.35, top_scale=0.9, open_start=True)
    t3.drop_facing(rack, (0, 0, -1))
    t3.mat(rack, "trim")
    upper.append(rack)
    tubes = air.plate("rocket_tubes", (-2.9, -2.31, 7.0), (0.52, 0, 0), (0, 0, 0.44), (0, -1, 0))
    t3.mat(tubes, "glow")
    upper.append(tubes)

    for obj in upper:
        common.art_group(obj, "torso")
    common.art_group(chest, "torso", pivot=True, kind="turret", weapon=1)
    objects = list(upper)

    # Legs: armoured columns, thick at the thigh and narrowing to the ankle, on sloped wedge feet. Each leg is
    # its own walking piece swinging fore and aft about its hip, inside the chest's base.
    for side, group, phase in ((1.0, "leg_l", 0.0), (-1.0, "leg_r", 0.5)):
        leg = air.block(f"leg_{side:+.0f}", 1.2, 1.4, 4.9, 1.8, 2.0, top_offset=(-side * 0.1, 0.1),
                        origin=(side * 1.35, 0.0, 0.9))
        air.drop_faces(leg, [0, 1])  # its ends are inside the foot and the chest
        foot = t3.wedge(f"foot_{side:+.0f}", 1.9, 3.0, 1.2, 0.6, origin=(side * 1.4, -0.5, 0.0), ridge_x=1.5)
        hip = (side * 1.3, 0.1, HIP_Z)
        objects.append(t3.leg_piece(f"leg_{side:+.0f}", [leg, foot], hip, "body", group,
                                    axis=(1.0, 0.0, 0.0), swing=SWING, phase=phase, stride=STRIDE))

    air.flat(objects)
    air.check_fit(objects, RADIUS, HEIGHT, DEF)
    return objects
