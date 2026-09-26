"""unit_defs/bot_t2.luau `recluse` (armsptk in BAR): the all-terrain rocket spider, at most 100 triangles. A low hexagonal body slung between four long ridged legs that
rise to high knees and come down to points far out on the diagonals, a pair of glowing eyes on its front, and a
team-coloured rocket pod on its back with three glowing tubes for its three-rocket burst. The pod turns to aim;
body and legs stay put.
"""

import math

from .shared import bot_t2 as bt
from .shared import palette
from .shared.bot_t2 import FRONT, UP, oring, tri_ring, vring

CATEGORY = "entity"
DEF = "recluse"
# its legs sweep about the vertical as it walks, carrying its splayed feet past the corners of its footprint
ENVELOPE = {"width": 4.42, "length": 4.42}
MOUNTS = {
    1: {"pivot": (0, 1.6372, 0), "muzzle": (-0.6309, 0.1754, 0.8598)},
}


def generate(params):
    bot = bt.Bot("recluse", params["color"], glow=palette.SPIDER_EYE)

    # body: a low hexagon, widest at its middle; its top is hidden under the pod mount
    mid = oring(0.0, 0.0, 1.0, 0.95, 0.85, n=6, turn=0.0)
    top = oring(0.0, 0.05, 1.4, 0.62, 0.55, n=6, turn=0.0)
    bot.put("body", bt.sweep_faces([oring(0.0, 0.0, 0.62, 0.55, 0.48, n=6, turn=0.0), mid, top],
                                   cap_start=False, cap_end=False))
    bot.put("body", bt.panel_faces(top, UP))

    # four legs on the diagonals: from the body's side up to a high knee, then down to a point on the ground
    for i in range(4):
        a = math.radians(45.0 + 90.0 * i)
        c, s = math.cos(a), math.sin(a)
        hip = tri_ring((0.6 * c, 0.6 * s, 1.05), a, 0.42, 0.42)
        knee = tri_ring((1.2 * c, 1.2 * s, 1.95), a, 0.32, 0.34)
        tip = tri_ring((1.8 * c, 1.8 * s, 0.04), a, 0.08, 0.08)
        # each leg sweeps about the vertical through its root; diagonal pairs step together (front-left with
        # back-right, the unit's left being +X and its front -Y), and a cycle covers about what the tip sweeps
        phase = 0.0 if (c > 0) != (s > 0) else 0.5
        bot.leg(f"leg_{i + 1}", "trim", bt.sweep_faces([hip, knee, tip], cap_start=False, cap_end=False),
                (0.6 * c, 0.6 * s, 1.05), (0, 0, 1), 0.3, round(4.0 * 1.2 * math.sin(0.3), 3), phase)

    # eyes on the body's front face
    for side in (1.0, -1.0):
        x = side * 0.2
        bot.put("glow", bt.panel_faces([(x - 0.1, -0.81, 1.02), (x + 0.1, -0.81, 1.02),
                                        (x + 0.08, -0.72, 1.18), (x - 0.08, -0.72, 1.18)], FRONT))

    # rocket pod on the back, turning to aim; three glowing tubes in its face
    T = "turret_1"
    bot.group(T, (0.0, 0.0, 1.4), kind="turret", weapon=1)
    face = vring(0.0, -0.58, 1.66, 1.05, 0.44)
    bot.put("accent", bt.sweep_faces([vring(0.0, 0.55, 1.7, 0.95, 0.6), face], cap_end=False, skip=((0, 0, -1),)), T)
    for k in (-1, 0, 1):
        bot.put("glow", bt.panel_faces(vring(k * 0.32, -0.586, 1.66, 0.22, 0.22), FRONT), T)

    return bot.finish()
