"""HUD icon: the Attack order, a crosshair: a ring, four ticks through it and a dot. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    ticks = [
        ic.bar((0.0, 0.6), (0.0, 1.95), 0.4),
        ic.bar((0.0, -0.6), (0.0, -1.95), 0.4),
        ic.bar((0.6, 0.0), (1.95, 0.0), 0.4),
        ic.bar((-0.6, 0.0), (-1.95, 0.0), 0.4),
    ]
    return ic.build("attack", [ic.layer([ic.ring(0.0, 0.0, 1.5, 1.08)] + ticks + [ic.circle(0.0, 0.0, 0.3, 12)], palette.ICON_FILL)])
