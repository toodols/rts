"""unit_defs/bot_t2.luau `mammoth` (corsumo in BAR): the heaviest bot there is, capsule(60, 60, 60) -- 2.7 studs
of radius, 5.45 tall, at most 100 triangles. Where the Sumo is a squat block on stubby legs, the Mammoth is built
like its name: thick bent pillar legs flaring into round-shouldered elephant feet, a hunched hull whose armored back
slopes down to the front, great shoulder humps, and one huge heavy laser pushed out of the chest like a trunk.
Everything above the waist turns to aim.
"""

from . import bot_t2_common as bt
from .bot_t2_common import FRONT, UP, hring, vring


def generate(params):
    bot = bt.Bot("mammoth", bt.rgb(226, 178, 74), glow=(1.0, 0.22, 0.12, 1.0), collider=bt.collider(60, 60, 60))

    # legs: one sweep each from a broad foot on the ground, through the ankle and a forward knee, up into the hull
    leg = bt.sweep_faces([hring(1.2, -0.1, 0.0, 1.15, 1.55), hring(1.2, -0.05, 0.45, 0.8, 0.95),
                          hring(1.25, -0.35, 1.4, 0.82, 0.86), hring(1.0, 0.1, 2.5, 0.8, 0.9)],
                         cap_start=False, cap_end=False)
    bot.biped("body", leg, hip=(1.0, 0.1, 2.5), swing=0.25)  # each leg walks as one piece from its hip

    T = "turret_1"
    waist = 2.2
    bot.group(T, (0.0, 0.0, waist), kind="turret", weapon=1)
    # hull: narrow at the waist, broad at the shoulders; its back armor slopes down toward the front
    back = [(-0.85, -0.55, waist + 1.75), (0.85, -0.55, waist + 1.75), (0.95, 0.9, waist + 2.6), (-0.95, 0.9, waist + 2.6)]
    bot.put("body", bt.sweep_faces([hring(0.0, 0.1, waist, 1.7, 1.4), hring(0.0, 0.0, waist + 1.0, 2.6, 2.0), back],
                                   cap_start=False, cap_end=False), T)
    bot.put("accent", bt.panel_faces(back, UP), T)
    # shoulder humps, rising above the back
    for side in (1.0, -1.0):
        hump = bt.block_faces(0.75, 1.7, 1.6, origin=(side * 1.55, 0.1, waist + 0.5), top=(0.45, 1.1),
                              top_offset=(side * 0.05, 0.15))
        bot.put("accent", hump, T)
    # the trunk: a heavy laser from inside the chest, drooping slightly, its muzzle glowing
    muzzle = vring(0.0, -2.62, waist + 0.75, 0.34, 0.34)
    bot.put("body", bt.sweep_faces([vring(0.0, -0.8, waist + 0.95, 0.66, 0.66), muzzle],
                                   cap_start=False, cap_end=False), T)
    bot.put("glow", bt.panel_faces(muzzle, FRONT), T)
    # visor across the hull front, under the sloped back
    bot.put("glow", bt.panel_faces([(-0.6, -1.02, waist + 1.35), (0.6, -1.02, waist + 1.35),
                                    (0.55, -0.72, waist + 1.62), (-0.55, -0.72, waist + 1.62)], FRONT), T)

    return bot.finish()
