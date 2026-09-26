"""unit_defs/bot_t2.luau `gunslinger` (armmav in BAR): the self-mending rifle bot, at most 100 triangles. A broad-shouldered gunfighter, unlike the Sharpshooter's thin stilts:
splayed legs planted on heavy boots, a chest that widens to a square, team-coloured shoulder line, a small head
with a glowing visor, a great armored pauldron on the left shoulder, and the whole right forearm a heavy rifle
levelled forward. The torso and gun arm turn together to aim.
"""

from .shared import bot_t2 as bt
from .shared import palette
from .shared.bot_t2 import FRONT, UP, hring, vring

CATEGORY = "entity"
DEF = "gunslinger"
MOUNTS = {
    1: {"pivot": (0, 2.1983, -0.0277), "muzzle": (1.1127, 0.7584, 1.6641)},
}


def generate(params):
    bot = bt.Bot("gunslinger", params["color"], glow=palette.MENDING_GREEN)

    # splayed legs in a wide stance, from the boots up into the torso
    leg = bt.sweep_faces([hring(0.72, 0.0, 0.28, 0.4, 0.44), hring(0.42, 0.02, 2.15, 0.5, 0.56)],
                         cap_start=False, cap_end=False)
    boot = bt.block_faces(0.6, 1.0, 0.34, origin=(0.72, -0.1, 0.0), top=(0.44, 0.56), top_offset=(0.0, 0.12))
    bot.biped("body", leg + boot, hip=(0.42, 0.02, 2.15), swing=0.32)  # leg and boot walk as one piece

    T = "turret_1"
    hips = 2.0
    bot.group(T, (0.0, 0.0, hips), kind="turret", weapon=1)
    # torso: waist, broad chest, a square shoulder line carrying the team colour
    shoulders = hring(0.0, 0.05, 3.55, 1.55, 0.85)
    bot.put("body", bt.sweep_faces([hring(0.0, 0.05, hips - 0.1, 0.9, 0.65), hring(0.0, -0.02, 3.05, 1.65, 1.0),
                                    shoulders], cap_start=False, cap_end=False), T)
    bot.put("accent", bt.panel_faces(shoulders, UP), T)
    # small head with a visor
    bot.put("body", bt.block_faces(0.5, 0.5, 0.42, origin=(0.0, -0.12, 3.55), top=(0.4, 0.36),
                                   top_offset=(0.0, 0.04)), T)
    bot.put("glow", bt.panel_faces([(-0.2, -0.371, 3.66), (0.2, -0.371, 3.66),
                                    (0.19, -0.35, 3.8), (-0.19, -0.35, 3.8)], FRONT), T)
    # left pauldron
    bot.put("accent", bt.block_faces(0.6, 1.0, 1.0, origin=(-0.95, 0.02, 2.75), top=(0.4, 0.7),
                                     top_offset=(-0.05, 0.0)), T)
    # right forearm rifle, dark gunmetal, levelled forward from the shoulder past the toes
    x = 0.95
    muzzle = vring(x, -1.2, 2.8, 0.2, 0.22)
    bot.put("trim", bt.sweep_faces([vring(x, 0.4, 3.1, 0.36, 0.55), vring(x, -0.45, 2.85, 0.34, 0.4), muzzle],
                                   cap_start=False, cap_end=False), T)
    bot.put("glow", bt.panel_faces(muzzle, FRONT), T)

    return bot.finish()
