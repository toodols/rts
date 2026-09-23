"""unit_defs/bot_t1.luau `construction_bot` (armck/corck): the T1 builder bot.

A squat, boxy worker: a stocky torso with a big team-coloured equipment pack on its back, a small
head with a green-lit visor, and one long elbowed nanolathe arm in high-vis yellow reaching forward
off the right shoulder, ending in a glowing emitter. The upper body turns toward what it builds
(kind "work"); each leg swings about its hip as it walks.

Collider capsule(27, 30, 27): radius 1.23, height 2.73 studs. Budget: 100 triangles.
"""

from . import bot_t1_common as bt

ACCENT = bt.rgb(226, 178, 74)


def generate(params):
    m = bt.Mats("construction_bot", ACCENT, bt.NANO_GLOW)

    upper = []
    torso = m.body(bt.slab("torso", 0.62, 0.48, 0.58, top_w=0.72, top_d=0.54, origin=(0.0, 0.0, 1.04)))
    upper.append(torso)
    upper.append(m.accent(bt.slab("pack", 0.64, 0.34, 0.66, top_w=0.56, top_d=0.28, top_offset=(0.0, 0.02), origin=(0.0, 0.36, 1.08))))
    upper.append(m.body(bt.slab("head", 0.3, 0.3, 0.22, top_w=0.22, top_d=0.22, top_offset=(0.0, 0.02), origin=(-0.1, -0.12, 1.62))))
    upper.append(m.glow(bt.visor("visor", -0.1, -0.275, 1.73, 0.22, 0.07, lean=0.012)))
    # the nanolathe arm: up from the right shoulder to a raised elbow, then down and forward to the emitter
    upper.append(m.nano(bt.limb("nano_arm", [(0.4, 0.06, 1.46), (0.5, -0.24, 1.86), (0.5, -0.72, 1.5)], [(0.2, 0.22), (0.17, 0.18), (0.16, 0.16)], cap=True)))
    # the emitter: a glowing nozzle flaring out of the wrist, its wide face toward the build
    upper.append(m.glow(bt.pyramid("emitter", (0.5, -0.8, 1.38), 0.24, 0.24, (0.5, -0.66, 1.56), base=True)))

    # each leg is one rigid piece swinging about its hip while the unit walks, the two half a cycle apart
    legs = []
    for name, side, phase in (("leg_l", -1.0, 0.0), ("leg_r", 1.0, 0.5)):
        hip = (side * 0.28, 0.0, 1.1)
        parts = bt.leg(m, name, hip, (side * 0.32, -0.12, 0.62), (side * 0.34, 0.0), 0.3, 0.56, 0.26, 0.23)
        legs.append(bt.walking_leg(name, parts, hip, m.trim, phase, 0.38))

    bt.group(upper, "torso", torso, kind="work")
    objs = upper + legs
    bt.finish(objs)
    bt.check_fit(objs, *bt.collider(27, 30, 27), "construction_bot")
    return objs
