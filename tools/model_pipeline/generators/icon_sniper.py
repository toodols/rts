"""HUD icon: sniper rifles, one long round with streaks behind it. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    casing = ic.poly(((-1.35, -0.3), (0.35, -0.3), (0.62, -0.19), (0.62, 0.19), (0.35, 0.3), (-1.35, 0.3)))
    tip = ic.poly(((0.62, -0.19), (1.25, -0.14), (1.7, -0.06), (1.9, 0.0), (1.7, 0.06), (1.25, 0.14), (0.62, 0.19)))
    streaks = [ic.bar((-1.95, 0.62), (-0.6, 0.62), 0.18), ic.bar((-1.95, -0.62), (-0.6, -0.62), 0.18)]
    angle = 35.0
    return ic.build(
        "sniper",
        [
            ic.layer(ic.place(streaks, angle=angle), palette.ICON_FILL),
            ic.layer(ic.place([casing], angle=angle), palette.ICON_FILL),
            ic.layer(ic.place([tip], angle=angle), palette.ICON_FILL),
        ],
    )
