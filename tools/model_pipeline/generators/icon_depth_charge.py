"""HUD icon: depth charges, a banded drum sinking under a wave. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    wave = ic.wave(-1.95, 1.95, 1.5, 0.14, 1.3, 0.36, segments=20)
    drum = ic.rounded_rect(-0.95, -1.8, 0.95, 0.75, 0.22, 3)
    hoops = [ic.rect(-0.95, -1.28, 0.95, -1.02), ic.rect(-0.95, -0.02, 0.95, 0.24)]
    bubbles = [ic.circle(-1.4, -0.35, 0.2, 10), ic.circle(1.45, -0.85, 0.17, 10), ic.circle(1.35, 0.2, 0.13, 8)]
    return ic.build(
        "depth_charge",
        [
            ic.layer([wave] + bubbles, ic.ICON),
            ic.layer([drum], ic.ICON),
            ic.layer(hoops, ic.OUTLINE, rim=None),
        ],
    )
