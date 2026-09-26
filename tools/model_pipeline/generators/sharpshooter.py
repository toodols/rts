"""unit_defs/bot_t2.luau `sharpshooter` (armsnipe in BAR): the sniper bot, at most 100 triangles. Tall and thin: long stilt legs with forward knees under a slim torso and a
dark sensor head, the torso in the team colour, with a rifle as long as the unit is wide resting on its right shoulder -- stock
behind, scope on top, barrel far out in front ending in a glowing muzzle. The torso and rifle turn to aim.
"""

from .shared import bot_t2 as bt
from .shared import palette
from .shared.bot_t2 import FRONT, UP, hring, vring

CATEGORY = "entity"
DEF = "sharpshooter"
MOUNTS = {
    1: {"pivot": (0, 2.1448, 0), "muzzle": (0.818, 1.4209, 1.3636)},
}


def generate(params):
    bot = bt.Bot("sharpshooter", params["color"], glow=palette.SNIPER_YELLOW)

    # stilt legs: a pointed foot on the ground, a knee well forward, the hip under the torso
    leg = bt.sweep_faces([hring(0.45, -0.08, 0.0, 0.36, 0.72), hring(0.52, -0.3, 1.1, 0.28, 0.32),
                          hring(0.36, 0.05, 2.2, 0.36, 0.4)], cap_start=False, cap_end=False)
    bot.biped("body", leg, hip=(0.36, 0.05, 2.2), swing=0.3)  # each stilt walks as one piece from its hip

    T = "turret_1"
    hips = 2.0
    bot.group(T, (0.0, 0.0, hips), kind="turret", weapon=1)
    # slim torso, widening to the shoulders
    top = hring(0.0, 0.05, 3.35, 0.8, 0.55)
    bot.put("accent", bt.sweep_faces([hring(0.0, 0.05, hips - 0.1, 0.72, 0.5), hring(0.0, 0.0, 2.85, 1.05, 0.72),
                                      top], cap_start=False, cap_end=False), T)
    bot.put("trim", bt.panel_faces(top, UP), T)
    # small wedge head with a single wide eye
    bot.put("trim", bt.block_faces(0.42, 0.5, 0.38, origin=(-0.12, -0.05, 3.35), top=(0.32, 0.3),
                                     top_offset=(0.0, 0.08)), T)
    bot.put("glow", bt.panel_faces([(-0.3, -0.301, 3.44), (0.06, -0.301, 3.44),
                                    (0.04, -0.27, 3.56), (-0.28, -0.27, 3.56)], FRONT), T)
    # the rifle on the right shoulder: stock, receiver, long thinning barrel
    x, z = 0.62, 3.38
    stock = vring(x, 0.98, z - 0.1, 0.18, 0.38)
    muzzle = vring(x, -1.14, z, 0.11, 0.11)
    bot.put("body", bt.sweep_faces([stock, vring(x, 0.25, z, 0.28, 0.34), vring(x, -0.28, z, 0.15, 0.15), muzzle],
                                   cap_end=False), T)
    bot.put("glow", bt.panel_faces(muzzle, FRONT), T)
    # scope on top of the receiver
    bot.put("body", bt.block_faces(0.14, 0.6, 0.16, origin=(x, 0.15, z + 0.16), top=(0.13, 0.5)), T)

    return bot.finish()
