"""HUD icon: shotguns, a shotgun shell, its pellets spreading out of its mouth. Written to src/shared/ui_art/ (see icon_common)."""

import math

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    base = ic.rect(-0.55, -1.62, 0.55, -1.4)
    brass = ic.rect(-0.47, -1.45, 0.47, -0.9)
    hull = ic.rect(-0.43, -0.9, 0.43, 0.62)
    pellets = []
    for a in (-24.0, 0.0, 24.0):
        for d, r in ((1.2, 0.23), (1.85, 0.2)):
            pellets.append(ic.circle(d * math.sin(math.radians(a)), 0.62 + d * math.cos(math.radians(a)), r, 10))
    shift, angle, scale = (0.0, -0.55), -35.0, 0.88
    return ic.build(
        "shotgun",
        [
            ic.layer(ic.place(pellets, shift, angle, scale), ic.ICON),
            ic.layer(ic.place([hull], shift, angle, scale), ic.ICON),
            ic.layer(ic.place([brass, base], shift, angle, scale), ic.ICON),
        ],
    )
