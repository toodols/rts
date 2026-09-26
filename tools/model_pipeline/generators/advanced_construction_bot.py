"""unit_defs/bot_t2.luau `advanced_construction_bot` (corack): the Advanced Bot Lab's builder, at most 100 triangles. A stocky walker with a team-coloured backpack (its
nanolathe feed), high-vis yellow shoulders and two of the builders' yellow nanolathe arms, one off each shoulder: up
to elbows splayed out over its head, then forward and down to glowing green emitters. The two arms are what tell it
from the one-armed construction bot at a distance: from above it is a yellow U. The torso, arms and emitters turn
together toward whatever it is building (kind "work"). The legs flare out to the ground rather than end in feet.
"""

from .shared import bot_t2 as bt
from .shared import palette
from .shared.bot_t2 import FRONT, UP, hring, vring

CATEGORY = "entity"
DEF = "advanced_construction_bot"


def generate(params):
    bot = bt.Bot("advanced_construction_bot", params["color"], glow=palette.NANO)

    # sturdy bent legs, flaring out to a broad footing on the ground
    leg = bt.sweep_faces([hring(0.52, -0.12, 0.0, 0.5, 0.8), hring(0.56, -0.2, 1.0, 0.42, 0.46),
                          hring(0.38, 0.02, 1.75, 0.44, 0.5)],
                         cap_start=False, cap_end=False)
    bot.biped("body", leg, hip=(0.38, 0.02, 1.75), swing=0.35)

    W = "work"
    hips = 1.6
    bot.group(W, (0.0, 0.0, hips), kind="work")
    # torso: waist, chest, shoulders
    shoulders = hring(0.0, 0.0, 2.95, 1.2, 0.8)
    bot.put("body", bt.sweep_faces([hring(0.0, 0.0, hips - 0.1, 0.85, 0.62), hring(0.0, -0.03, 2.5, 1.35, 0.9),
                                    shoulders], cap_start=False, cap_end=False), W)
    bot.put("hivis", bt.panel_faces(shoulders, UP), W)
    # backpack: the nanolathe feed, its front face against the torso
    bot.put("accent", bt.block_faces(1.0, 0.5, 1.15, origin=(0.0, 0.62, 1.95), top=(0.85, 0.4),
                                     top_offset=(0.0, 0.03), skip=((0, 0, -1), FRONT)), W)
    # visor
    bot.put("glow", bt.panel_faces([(-0.3, -0.476, 2.62), (0.3, -0.476, 2.62),
                                    (0.28, -0.42, 2.8), (-0.28, -0.42, 2.8)], FRONT), W)
    # the nanolathe arms: from each shoulder up to an elbow splayed out over the head, then forward and down to an
    # emitter
    for side in (-1.0, 1.0):
        wrist = vring(side * 0.66, -0.95, 2.95, 0.2, 0.2)
        bot.put("hivis", bt.sweep_faces([hring(side * 0.5, 0.1, 2.85, 0.34, 0.4), vring(side * 0.78, -0.25, 3.62, 0.28, 0.32),
                                         wrist], cap_start=False, cap_end=False), W)
        # emitter: a glowing point pushed out of the wrist, forward and down toward the build
        bot.put("glow", bt.pyramid_faces(wrist, (side * 0.62, -1.16, 2.64)), W)

    return bot.finish()
