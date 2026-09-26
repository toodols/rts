"""unit_defs/bot_t2.luau `sumo`: Cortex's armored assault bot, at most 100 triangles. A squat, top-heavy brawler: short splayed legs on broad feet under a chest that
widens to the shoulders, two big team-coloured shoulder slabs, a slit visor, and a twin laser jutting from the
lower chest. The torso turns on the waist to aim.
"""

from .shared import bot_t2 as bt
from .shared import palette
from .shared.bot_t2 import DOWN, FRONT, LEFT, RIGHT, UP, hring, vring

CATEGORY = "entity"
DEF = "sumo"
MOUNTS = {
    1: {"pivot": (0, 1.2573, 0.0505), "muzzle": (0.5004, 0.482, 1.3131)},
}


def generate(params):
    bot = bt.Bot("sumo", params["color"], glow=palette.BEACON_RED)

    # legs: one stubby splayed column each, from the foot up into the torso (its top is buried there)
    leg = bt.sweep_faces([hring(0.66, 0.0, 0.22, 0.42, 0.5), hring(0.48, 0.0, 1.3, 0.5, 0.56)],
                         cap_start=False, cap_end=False)
    # broad wedge feet, toes forward; each leg and its foot walk as one piece swinging from the hip
    foot = bt.block_faces(0.58, 0.95, 0.26, origin=(0.66, -0.02, 0.0), top=(0.44, 0.56), top_offset=(0.0, 0.12))
    bot.biped("body", leg + foot, hip=(0.48, 0.0, 1.3), swing=0.3)

    T = "turret_1"
    waist = 1.2
    bot.group(T, (0.0, 0.0, waist), kind="turret", weapon=1)
    # chest: narrow at the waist, widest at the shoulders, a sloped cap on top
    top = hring(0.0, 0.1, waist + 1.75, 1.2, 0.8)
    bot.put("body", bt.sweep_faces([hring(0.0, 0.05, waist, 1.1, 0.85), hring(0.0, 0.0, waist + 1.05, 1.95, 1.25),
                                    top], cap_start=False, cap_end=False), T)
    bot.put("accent", bt.panel_faces(top, UP), T)  # the lid carries the team colour, seen from above
    # shoulder slabs: thick, overhanging the chest's sides; their inner faces are inside the chest
    for side in (1.0, -1.0):
        slab = bt.block_faces(0.5, 1.05, 1.0, origin=(side * 1.0, 0.05, waist + 0.55), top=(0.34, 0.8),
                              top_offset=(side * 0.06, 0.04), skip=(DOWN, LEFT if side > 0 else RIGHT))
        bot.put("accent", slab, T)
    # twin laser: square barrels from inside the chest out past the toes; their muzzles glow
    z = waist + 0.55
    for side in (1.0, -1.0):
        x = side * 0.34
        bot.put("body", bt.sweep_faces([vring(x, -0.35, z, 0.32, 0.32), vring(x, -1.3, z, 0.18, 0.18)],
                                       cap_start=False, cap_end=False), T)
        bot.put("glow", bt.panel_faces(vring(x, -1.3, z, 0.18, 0.18), FRONT), T)
    # slit visor high on the chest front
    bot.put("glow", bt.panel_faces([(-0.35, -0.49, waist + 1.4), (0.35, -0.49, waist + 1.4),
                                    (0.3, -0.36, waist + 1.58), (-0.3, -0.36, waist + 1.58)], FRONT), T)

    return bot.finish()
