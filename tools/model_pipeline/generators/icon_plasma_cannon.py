"""HUD icon: a plasma cannon's shot, a ball with a comet's tail behind it. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    cx, cy = 0.6, 0.6
    return ic.build(
        "plasma_cannon",
        [
            ic.layer([ic.teardrop(cx, cy, 0.95, 3.35, angle=225.0, segments=18)], palette.ICON_FILL),
            ic.layer([ic.teardrop(cx + 0.05, cy + 0.05, 0.55, 2.0, angle=225.0, segments=14)], palette.ICON_FILL),
        ],
    )
