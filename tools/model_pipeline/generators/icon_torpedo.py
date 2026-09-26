"""HUD icon: torpedoes, a torpedo running through the water, bubbles behind it. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    h = 0.4
    body = ic.rect(-0.95, -h, 1.25, h)
    nose = ic.poly([(1.25, -h)] + ic.arc_points(1.25, 0.0, h, -90.0, 90.0, 8)[1:-1] + [(1.25, h), (1.05, h), (1.05, -h)])
    tail = ic.poly(((-0.95, -h), (-0.95, h), (-1.4, 0.18), (-1.4, -0.18)))
    fins = ic.rect(-1.45, -0.7, -1.1, 0.7)
    bubbles = [ic.circle(-1.95, 0.45, 0.2, 10), ic.circle(-2.2, -0.1, 0.15, 8)]
    shift, angle = (0.3, 0.0), -12.0
    return ic.build(
        "torpedo",
        [
            ic.layer(ic.place(bubbles, shift, angle), palette.ICON_FILL),
            ic.layer(ic.place([fins, body, tail], shift, angle), palette.ICON_FILL),
            ic.layer(ic.place([nose], shift, angle), palette.ICON_FILL),
        ],
    )
