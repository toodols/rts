"""HUD icon: flamethrowers, a tongue of fire with a flame inside it. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"
FLAME = (
    (0.0, -1.9), (0.75, -1.72), (1.25, -1.2), (1.42, -0.45), (1.25, 0.3), (0.95, 0.85), (1.05, 1.45), (0.5, 1.05),
    (0.2, 1.95), (-0.25, 1.05), (-0.7, 1.35), (-0.72, 0.7), (-1.2, 0.3), (-1.42, -0.45), (-1.25, -1.2), (-0.75, -1.72),
)


def generate(params):
    outer = ic.poly(FLAME)
    middle = ic.transform(outer, scale=0.58, move=(0.0, -0.66))
    return ic.build("flamethrower", [ic.layer([outer], palette.ICON_FILL), ic.layer([middle], palette.ICON_FILL)])
