"""HUD icon: the Guard order, a heater shield with a line round its face. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def shield_points():
    right = [(0.0, -1.95)]
    # the right flank curves up from the point: a quadratic from the point through (1.4, -1.25) to (1.5, 0.25)
    for i in range(1, 8):
        t = i / 8.0
        x = (1 - t) ** 2 * 0.0 + 2 * (1 - t) * t * 1.4 + t * t * 1.5
        y = (1 - t) ** 2 * -1.95 + 2 * (1 - t) * t * -1.25 + t * t * 0.25
        right.append((x, y))
    right += [(1.5, 0.25), (1.5, 1.45), (0.75, 1.62), (0.0, 1.5)]
    # the right half runs bottom to top here; mirrored() wants it top to bottom
    return ic.mirrored(list(reversed(right)))


def generate(params):
    shield = ic.poly(shield_points())
    face = ic.grow(shield, -0.38)
    return ic.build(
        "guard",
        [
            ic.layer([shield], palette.ICON_FILL),
            ic.layer([face], palette.ICON_FILL),
        ],
    )
