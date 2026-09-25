"""HUD icon: the Attack order, a crosshair: a ring, four ticks through it and a dot. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    ticks = [
        ic.bar((0.0, 0.6), (0.0, 1.95), 0.4),
        ic.bar((0.0, -0.6), (0.0, -1.95), 0.4),
        ic.bar((0.6, 0.0), (1.95, 0.0), 0.4),
        ic.bar((-0.6, 0.0), (-1.95, 0.0), 0.4),
    ]
    return ic.build("attack", [ic.layer([ic.ring(0.0, 0.0, 1.5, 1.08)] + ticks + [ic.circle(0.0, 0.0, 0.3, 12)], ic.ICON)])
