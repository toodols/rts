"""unit_defs/bot_t2.luau `fatboy`: the heavy plasma bot, at
most 100 triangles. Its silhouette is its name: a big round octagonal belly, team-coloured above the belt, waddling on two
short stumpy legs with flared feet, with one fat plasma cannon on a housing on its back, reaching forward over its
head to a flared, glowing muzzle. The whole body turns on the hips to aim.
"""

from .shared import bot_t2 as bt
from .shared import palette
from .shared.bot_t2 import FRONT, UP, hring, oring, vring

CATEGORY = "entity"
DEF = "fatboy"
MOUNTS = {
    1: {"pivot": (0, 1.8182, 0), "muzzle": (0.4673, 2.8121, 2.7273)},
}


def generate(params):
    bot = bt.Bot("fatboy", params["color"], glow=palette.HEAVY_PLASMA)

    # stumpy legs flaring into broad feet, their tops buried in the belly
    leg = bt.sweep_faces([hring(1.12, -0.12, 0.0, 1.05, 1.4), hring(1.08, 0.0, 0.4, 0.62, 0.72),
                          hring(0.85, 0.05, 1.75, 0.72, 0.8)], cap_start=False, cap_end=False)
    bot.biped("trim", leg, hip=(0.85, 0.05, 1.75), swing=0.25)  # each leg waddles as one piece from its hip

    T = "turret_1"
    hips = 1.5
    bot.group(T, (0.0, 0.0, hips), kind="turret", weapon=1)
    # the belly: an octagon swelling from the hips to its widest and closing in toward a lid
    lid = oring(0.0, 0.15, 3.85, 1.45, 1.35)
    belt = oring(0.0, 0.0, 2.6, 2.05, 1.95)
    bot.put("body", bt.sweep_faces([oring(0.0, 0.05, hips - 0.2, 1.05), belt], cap_start=False, cap_end=False), T)
    # the upper belly carries the team colour; the lid stays gunmetal under the cannon
    bot.put("accent", bt.sweep_faces([belt, lid], cap_start=False, cap_end=False), T)
    bot.put("body", bt.panel_faces(lid, UP), T)
    # cannon housing on the back of the lid
    bot.put("body", bt.block_faces(1.2, 1.5, 0.75, origin=(0.0, 0.45, 3.75), top=(0.9, 1.1),
                                   top_offset=(0.0, 0.05)), T)
    # the plasma cannon: a thick barrel out over the front, flaring at the muzzle
    z = 4.15
    muzzle = vring(0.0, -2.6, z, 0.66, 0.66)
    bot.put("body", bt.sweep_faces([vring(0.0, -0.2, z, 0.52, 0.52), vring(0.0, -2.05, z, 0.42, 0.42), muzzle],
                                   cap_start=False, cap_end=False), T)
    bot.put("glow", bt.panel_faces(muzzle, FRONT), T)

    return bot.finish()
