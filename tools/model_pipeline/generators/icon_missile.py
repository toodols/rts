"""HUD icon: guided missiles, a missile with fins, puffs of its trail behind it. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    body = ic.poly(((-1.35, -0.3), (0.8, -0.3), (1.2, -0.22), (1.5, -0.1), (1.65, 0.0), (1.5, 0.1), (1.2, 0.22), (0.8, 0.3), (-1.35, 0.3)))
    tail = [ic.poly(((-1.35, 0.3), (-0.8, 0.3), (-1.3, 0.85), (-1.65, 0.85))), ic.poly(((-1.35, -0.3), (-1.65, -0.85), (-1.3, -0.85), (-0.8, -0.3)))]
    canards = [ic.poly(((0.3, 0.3), (0.7, 0.3), (0.45, 0.6), (0.25, 0.6))), ic.poly(((0.3, -0.3), (0.25, -0.6), (0.45, -0.6), (0.7, -0.3)))]
    trail = [ic.circle(-1.95, -0.55, 0.24, 10), ic.circle(-2.2, -1.15, 0.18, 8)]
    shift, angle, scale = (0.25, 0.3), 32.0, 0.9
    return ic.build(
        "missile",
        [
            ic.layer(ic.place(trail, shift, angle, scale), palette.ICON_FILL),
            ic.layer(ic.place(tail + canards, shift, angle, scale), palette.ICON_FILL),
            ic.layer(ic.place([body], shift, angle, scale), palette.ICON_FILL),
        ],
    )
