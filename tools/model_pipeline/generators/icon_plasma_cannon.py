"""HUD icon: a plasma cannon's shot, a ball with a comet's tail behind it. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    cx, cy = 0.6, 0.6
    return ic.build(
        "plasma_cannon",
        [
            ic.layer([ic.teardrop(cx, cy, 0.95, 3.35, angle=225.0, segments=18)], ic.ICON),
            ic.layer([ic.teardrop(cx + 0.05, cy + 0.05, 0.55, 2.0, angle=225.0, segments=14)], ic.ICON),
        ],
    )
