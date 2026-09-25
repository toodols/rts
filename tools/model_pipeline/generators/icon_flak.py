"""HUD icon: flak (anti-air cannon), a burst in a puff of smoke, with shrapnel flying out. Written to src/shared/ui_art/ (see icon_common)."""

import math

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    smoke = [ic.circle(-0.62, 0.3, 0.85, 18), ic.circle(0.6, 0.45, 0.9, 18), ic.circle(0.0, -0.45, 0.9, 18)]
    shrapnel = [ic.square(1.85 * math.cos(math.radians(a)), 0.05 + 1.85 * math.sin(math.radians(a)), 0.32, a) for a in (45.0, 135.0, 225.0, 315.0)]
    return ic.build(
        "flak",
        [
            ic.layer(smoke + shrapnel, ic.ICON),
            ic.layer([ic.star(0.0, 0.05, 1.15, 0.52, points=8, angle=0.0)], ic.ICON),
        ],
    )
