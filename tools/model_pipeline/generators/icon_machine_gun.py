"""HUD icon: machine guns (EMG and the like), three rounds side by side. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def bullet(x, y):
    casing = ic.rect(x - 0.32, y - 1.45, x + 0.32, y + 0.1)
    tip = ic.poly([(x + px, y + py) for px, py in ((0.32, 0.1), (0.31, 0.45), (0.23, 0.8), (0.12, 1.05), (0.0, 1.15), (-0.12, 1.05), (-0.23, 0.8), (-0.31, 0.45), (-0.32, 0.1))])
    return casing, tip


def generate(params):
    rounds = [bullet(-0.85, 0.25), bullet(0.0, 0.0), bullet(0.85, -0.25)]
    return ic.build("machine_gun", [ic.layer([c for c, _ in rounds], palette.ICON_FILL), ic.layer([t for _, t in rounds], palette.ICON_FILL)])
