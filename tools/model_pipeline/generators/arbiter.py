"""unit_defs/bot_t2.luau `arbiter` (corhrk): Cortex's heavy rocket bot, capsule(26, 31, 33) -- 1.5 studs of radius,
2.8 tall, at most 100 triangles. A small hunched walker on reverse-jointed legs, carrying a launcher box far bigger
than itself on its back: team-coloured sides, a dark lid with four glowing rocket cells facing the sky, since its
rockets climb straight up before diving onto their target. A squat sensor head peers out under the box. The body
and launcher turn together on the hips to aim.
"""

from . import bot_t2_common as bt
from .bot_t2_common import FRONT, UP, hring


def generate(params):
    bot = bt.Bot("arbiter", bt.rgb(196, 140, 84), glow=(1.0, 0.55, 0.15, 1.0), collider=bt.collider(26, 31, 33))

    # reverse-jointed legs: ankle, a knee bent backward, hip
    leg = bt.sweep_faces([hring(0.5, 0.0, 0.18, 0.3, 0.34), hring(0.6, 0.34, 0.78, 0.36, 0.4),
                          hring(0.45, -0.05, 1.42, 0.4, 0.44)], cap_start=False, cap_end=False)
    foot = bt.block_faces(0.46, 0.9, 0.2, origin=(0.5, -0.14, 0.0), top=(0.3, 0.5), top_offset=(0.0, 0.1))
    bot.biped("body", leg + foot, hip=(0.45, -0.05, 1.42), swing=0.4)  # leg and foot walk as one piece

    T = "turret_1"
    hips = 1.3
    bot.group(T, (0.0, 0.0, hips), kind="turret", weapon=1)
    # small body slung between the hips
    bot.put("body", bt.block_faces(1.05, 0.95, 0.65, origin=(0.0, -0.05, hips - 0.05), top=(0.85, 0.75)), T)
    # the launcher box on its back, leaning back a little
    # its lid slopes down to the front, so the rocket cells face up and forward, toward the camera
    front_z, back_z, y0, y1 = 2.5, 2.8, 0.02, 1.0

    def on_lid(x, y):
        return (x, y, front_z + (back_z - front_z) * (y - y0) / (y1 - y0) + 0.01)

    lid = [(-0.66, y0, front_z), (0.66, y0, front_z), (0.66, y1, back_z), (-0.66, y1, back_z)]
    bot.put("accent", bt.sweep_faces([hring(0.0, 0.45, hips + 0.25, 1.2, 0.95), hring(0.0, 0.5, hips + 0.75, 1.36, 1.0),
                                      lid], cap_end=False, skip=((0, 0, -1),)), T)
    bot.put("body", bt.panel_faces(lid, UP), T)
    # four rocket cells glowing in the lid
    for cx in (-0.3, 0.3):
        for cy in (0.28, 0.74):
            bot.put("glow", bt.panel_faces([on_lid(cx - 0.2, cy - 0.16), on_lid(cx + 0.2, cy - 0.16),
                                            on_lid(cx + 0.2, cy + 0.16), on_lid(cx - 0.2, cy + 0.16)], UP), T)
    # sensor head under the front of the box, with a visor slit
    bot.put("body", bt.block_faces(0.55, 0.5, 0.38, origin=(0.0, -0.5, hips + 0.55), top=(0.45, 0.36),
                                   top_offset=(0.0, 0.03)), T)
    bot.put("glow", bt.panel_faces([(-0.22, -0.756, hips + 0.68), (0.22, -0.756, hips + 0.68),
                                    (0.22, -0.748, hips + 0.8), (-0.22, -0.748, hips + 0.8)], FRONT), T)

    return bot.finish()
