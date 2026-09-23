"""unit_defs/bot_t1.luau `graverobber` (cornecro): Cortex's resurrection bot.

A hunched scavenger on long backward-kneed legs, head low at the front, a team-coloured shell over
its back, and its nanolathe carried like a scorpion's tail: a high-vis yellow boom arching up from
the back and over the head to a glowing emitter that points down at whatever it is raising or
reclaiming. The upper body turns toward its work (kind "work"); each leg swings about its hip as it walks.

Collider capsule(28, 34, 28): radius 1.27, height 3.09 studs. Budget: 100 triangles.
"""

from . import bot_t1_common as bt

ACCENT = bt.rgb(150, 176, 120)


def generate(params):
    m = bt.Mats("graverobber", ACCENT, bt.NANO_GLOW)

    upper = []
    # hunched torso: its top pitched forward over the hips
    torso = m.body(bt.hexa(
        "torso",
        [(-0.28, -0.16, 1.3), (0.28, -0.16, 1.3), (0.28, 0.38, 1.3), (-0.28, 0.38, 1.3)],
        [(-0.36, -0.38, 1.74), (0.36, -0.38, 1.74), (0.36, 0.16, 1.86), (-0.36, 0.16, 1.86)],
    ))
    upper.append(torso)
    # the shell over its back, sloping down to the rear
    upper.append(m.accent(bt.hexa(
        "shell",
        [(-0.42, -0.32, 1.76), (0.42, -0.32, 1.76), (0.42, 0.36, 1.5), (-0.42, 0.36, 1.5)],
        [(-0.3, -0.2, 1.94), (0.3, -0.2, 1.94), (0.3, 0.26, 1.78), (-0.3, 0.26, 1.78)],
    )))
    upper.append(m.body(bt.slab("head", 0.28, 0.3, 0.18, top_w=0.22, top_d=0.22, top_offset=(0.0, 0.02), origin=(0.0, -0.46, 1.5))))
    upper.append(m.glow(bt.visor("visor", 0.0, -0.615, 1.59, 0.22, 0.06, lean=0.01)))
    # the nanolathe tail: up from the back, arching over the head, the emitter hanging in front
    upper.append(m.nano(bt.limb(
        "nano_tail",
        [(0.0, 0.22, 1.7), (0.0, 0.46, 2.36), (0.0, 0.02, 2.82), (0.0, -0.5, 2.62)],
        [(0.2, 0.2), (0.17, 0.17), (0.15, 0.15), (0.13, 0.13)],
        cap=True,
    )))
    upper.append(m.glow(bt.pyramid("emitter", (0.0, -0.66, 2.38), 0.24, 0.24, (0.0, -0.5, 2.62), base=True)))

    legs = []
    # backward knees: the hip sits over the foot, the knee kicks out behind
    # each leg is one rigid piece swinging about its hip while the unit walks, the two half a cycle apart
    for name, side, phase in (("leg_l", -1.0, 0.0), ("leg_r", 1.0, 0.5)):
        hip = (side * 0.3, 0.0, 1.36)
        parts = bt.leg(m, name, hip, (side * 0.36, 0.42, 0.82), (side * 0.38, -0.02), 0.24, 0.52, 0.22, 0.18)
        legs.append(bt.walking_leg(name, parts, hip, m.trim, phase, 0.4))

    bt.group(upper, "torso", torso, kind="work")
    objs = upper + legs
    bt.finish(objs)
    bt.check_fit(objs, *bt.collider(28, 34, 28), "graverobber")
    return objs
