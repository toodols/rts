"""unit_defs/bot_t1.luau `centurion` (armwar): the anti-swarm bot with a laser on each side.

A heavy, broad-chested brawler on thick armored legs. Each shoulder carries its own laser pod -- a
team-coloured housing with twin dark emitter barrels -- on its own swivel, so the two can aim at
different targets as the def's two weapons do (offsets x -0.7 and +0.7). The body itself is static; each leg swings about its hip as it walks.

Collider capsule(30, 32, 30): radius 1.36, height 2.91 studs. Budget: 100 triangles.
"""

from . import bot_t1_common as bt

ACCENT = bt.rgb(120, 150, 196)
GLOW = (0.55, 0.85, 1.0, 1.0)  # blue laser


def generate(params):
    m = bt.Mats("centurion", ACCENT, GLOW)

    base = []
    chest = m.body(bt.slab("chest", 0.74, 0.56, 0.72, top_w=0.96, top_d=0.7, origin=(0.0, 0.0, 1.12)))
    base.append(chest)
    base.append(m.body(bt.slab("head", 0.34, 0.34, 0.28, top_w=0.26, top_d=0.24, top_offset=(0.0, 0.03), origin=(0.0, -0.18, 1.84))))
    base.append(m.glow(bt.visor("visor", 0.0, -0.355, 1.97, 0.28, 0.08, lean=0.015)))
    # thick armored legs, knees forward, the shins flaring into broad feet
    # each leg is one rigid piece swinging about its hip while the unit walks, the two half a cycle apart;
    # a heavy bot, so a short swing
    for name, side, phase in (("leg_l", -1.0, 0.0), ("leg_r", 1.0, 0.5)):
        hip = (side * 0.32, 0.0, 1.18)
        parts = bt.leg(m, name, hip, (side * 0.38, -0.14, 0.69), (side * 0.4, 0.0), 0.38, 0.54, 0.3, 0.28, shin_caps="")
        base.append(bt.walking_leg(name, parts, hip, m.body, phase, 0.32))

    guns = []
    for weapon, side in ((1, -1.0), (2, 1.0)):
        x = side * 0.7
        z = 1.7
        # the pod: shoulder and forearm in one, flaring out at the top
        pod = m.accent(bt.slab(f"pod_{weapon}", 0.3, 0.5, 0.6, top_w=0.4, top_d=0.62, top_offset=(side * 0.03, 0.0), origin=(x, 0.02, z - 0.34)))
        bt.set_pivot(pod, (x, 0.0, z))
        # the emitter: a thick square barrel out of the pod's front, necking down to a glowing-less tip
        barrels = m.trim(bt.beam(f"barrels_{weapon}", (x, -0.2, z), (x, -0.8, z), 0.2, 0.2, 0.15, 0.15, caps=""))
        muzzle = m.accent(bt.pyramid(f"muzzle_{weapon}", (x, -0.8, z), 0.12, 0.12, (x, -0.92, z)))
        bt.group([pod, barrels, muzzle], f"turret_{weapon}", pod, kind="turret", weapon=weapon)
        guns += [pod, barrels, muzzle]

    objs = base + guns
    bt.finish(objs)
    bt.check_fit(objs, *bt.collider(30, 32, 30), "centurion")
    return objs
