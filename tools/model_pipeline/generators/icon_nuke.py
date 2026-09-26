"""HUD icon: nuclear missiles, a dark radiation trefoil on a disc. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def trefoil(scale=1.0):
    blades = [ic.arc_band(0.0, 0.0, 0.5 * scale, 1.55 * scale, a - 30.0, a + 30.0, 6) for a in (30.0, 150.0, 270.0)]
    return blades + [ic.circle(0.0, 0.0, 0.32 * scale, 12)]


def generate(params):
    return ic.build("nuke", [ic.layer([ic.circle(0.0, 0.0, 1.9, 28)], palette.ICON_FILL), ic.layer(trefoil(), palette.ICON_OUTLINE, rim=None)])
