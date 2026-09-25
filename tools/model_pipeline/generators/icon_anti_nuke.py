"""HUD icon: anti-nukes, a radiation trefoil struck through by a prohibition sign. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    blades = [ic.arc_band(0.0, 0.0, 0.36, 1.1, a - 30.0, a + 30.0, 5) for a in (30.0, 150.0, 270.0)]
    sign = [ic.ring(0.0, 0.0, 1.95, 1.48, 28), ic.bar((-1.2, 1.2), (1.2, -1.2), 0.46)]
    return ic.build(
        "anti_nuke",
        [
            ic.layer([ic.circle(0.0, 0.0, 1.55, 28)], ic.ICON, rim=None),
            ic.layer(blades + [ic.circle(0.0, 0.0, 0.23, 10)], ic.OUTLINE, rim=None),
            ic.layer(sign, ic.ICON),
        ],
    )
