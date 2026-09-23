"""unit_defs/bot_t2.luau `advanced_construction_bot` (corack): the Advanced Bot Lab's builder, capsule(28, 42, 30) --
1.36 studs of radius, 3.8 tall, at most 100 triangles. A stocky walker with a team-coloured backpack (its
nanolathe feed) and, rising off its right shoulder, the builders' high-vis yellow nanolathe arm: up to an elbow over
its head, then forward and down to a glowing green emitter. The torso, arm and emitter turn together toward whatever
it is building (kind "work"); legs stay put.
"""

from . import bot_t2_common as bt
from .bot_t2_common import FRONT, UP, hring, vring


def generate(params):
    bot = bt.Bot("advanced_construction_bot", bt.rgb(226, 178, 74), glow=(0.35, 0.95, 0.75, 1.0),
                 collider=bt.collider(28, 42, 30))

    # sturdy bent legs on wedge feet
    leg = bt.sweep_faces([hring(0.5, 0.0, 0.24, 0.34, 0.4), hring(0.56, -0.2, 1.0, 0.42, 0.46),
                          hring(0.38, 0.02, 1.75, 0.44, 0.5)],
                         cap_start=False, cap_end=False)
    foot = bt.block_faces(0.5, 0.9, 0.26, origin=(0.52, -0.1, 0.0), top=(0.36, 0.5), top_offset=(0.0, 0.12))
    bot.biped("body", leg + foot, hip=(0.38, 0.02, 1.75), swing=0.35)  # leg and foot walk as one piece

    W = "work"
    hips = 1.6
    bot.group(W, (0.0, 0.0, hips), kind="work")
    # torso: waist, chest, shoulders
    shoulders = hring(0.0, 0.0, 2.95, 1.2, 0.8)
    bot.put("body", bt.sweep_faces([hring(0.0, 0.0, hips - 0.1, 0.85, 0.62), hring(0.0, -0.03, 2.5, 1.35, 0.9),
                                    shoulders], cap_start=False, cap_end=False), W)
    bot.put("accent", bt.panel_faces(shoulders, UP), W)
    # backpack: the nanolathe feed, its front face against the torso
    bot.put("accent", bt.block_faces(1.0, 0.5, 1.15, origin=(0.0, 0.62, 1.95), top=(0.85, 0.4),
                                     top_offset=(0.0, 0.03), skip=((0, 0, -1), FRONT)), W)
    # visor
    bot.put("glow", bt.panel_faces([(-0.3, -0.476, 2.62), (0.3, -0.476, 2.62),
                                    (0.28, -0.42, 2.8), (-0.28, -0.42, 2.8)], FRONT), W)
    # the nanolathe arm: from the right shoulder up to an elbow over the head, then out and down to the emitter
    wrist = vring(0.6, -0.95, 2.95, 0.2, 0.2)
    bot.put("hivis", bt.sweep_faces([hring(0.58, 0.1, 2.85, 0.36, 0.4), vring(0.6, -0.25, 3.62, 0.3, 0.34), wrist],
                                    cap_start=False, cap_end=False), W)
    # emitter: a glowing point pushed out of the wrist, forward and down toward the build
    bot.put("glow", bt.pyramid_faces(wrist, (0.6, -1.16, 2.64)), W)

    return bot.finish()
