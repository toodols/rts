"""HUD icon: metal, a stack of three ingots. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def ingot(cx, cy):
    # a bar seen side on: wider at its foot than its top
    return ic.poly(((cx - 0.95, cy - 0.5), (cx + 0.95, cy - 0.5), (cx + 0.7, cy + 0.5), (cx - 0.7, cy + 0.5)))


def generate(params):
    return ic.build(
        "metal",
        [
            ic.layer([ingot(-0.98, -0.85), ingot(0.98, -0.85)], palette.ICON_FILL),
            ic.layer([ingot(0.0, 0.3)], palette.ICON_FILL),
        ],
    )
