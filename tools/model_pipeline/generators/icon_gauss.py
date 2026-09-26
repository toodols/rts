"""HUD icon: gauss cannons, a slug fired from between two rails. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    rails = [ic.bar((-1.95, 0.85), (0.9, 0.85), 0.42), ic.bar((-1.95, -0.85), (0.9, -0.85), 0.42)]
    slug = ic.poly(((-1.5, -0.34), (0.95, -0.34), (1.5, -0.18), (1.9, 0.0), (1.5, 0.18), (0.95, 0.34), (-1.5, 0.34)))
    angle = 25.0
    return ic.build("gauss", [ic.layer(ic.place(rails, angle=angle), palette.ICON_FILL), ic.layer(ic.place([slug], angle=angle), palette.ICON_FILL)])
