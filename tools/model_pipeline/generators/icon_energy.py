"""HUD icon: energy, a coin with a lightning bolt cut through it. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    bolt, _ = ic.transform(ic.poly(ic.BOLT), scale=0.72, move=(-0.1, 0.0))
    coin = ic.poly(ic.circle_points(0.0, 0.0, 1.9, 32), [bolt])
    return ic.build("energy", [ic.layer([coin], palette.ICON_FILL)])
