"""HUD icon: nuclear missiles, a dark radiation trefoil on a disc. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def trefoil(scale=1.0):
    blades = [ic.arc_band(0.0, 0.0, 0.5 * scale, 1.55 * scale, a - 30.0, a + 30.0, 6) for a in (30.0, 150.0, 270.0)]
    return blades + [ic.circle(0.0, 0.0, 0.32 * scale, 12)]


def generate(params):
    return ic.build("nuke", [ic.layer([ic.circle(0.0, 0.0, 1.9, 28)], ic.ICON), ic.layer(trefoil(), ic.OUTLINE, rim=None)])
