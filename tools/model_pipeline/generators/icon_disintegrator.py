"""HUD icon: the commander's Disintegrator (D-gun), a searing ball, the bits of whatever it hit trailing off behind it. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    cx, cy = 0.45, 0.4
    fragments = [ic.square(-0.95, -0.6, 0.5, 20.0), ic.square(-1.5, -1.15, 0.38, 40.0), ic.square(-1.9, -1.65, 0.26, 10.0)]
    return ic.build(
        "disintegrator",
        [
            ic.layer(fragments + [ic.star(cx, cy, 1.5, 1.08, points=11, angle=12.0)], palette.ICON_FILL),
            ic.layer([ic.circle(cx, cy, 0.72, 20)], palette.ICON_FILL),
        ],
    )
