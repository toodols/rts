"""HUD icon: the Fight order (attack-move), two crossed swords. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def sword(angle):
    blade = ic.poly(((-0.25, -0.5), (0.25, -0.5), (0.25, 1.35), (0.0, 1.85), (-0.25, 1.35)))
    hilt = [ic.rect(-0.7, -0.8, 0.7, -0.5), ic.rect(-0.16, -1.42, 0.16, -0.8), ic.circle(0.0, -1.55, 0.25, 10)]
    return ic.place([blade] + hilt, shift=(0.0, -0.15), angle=angle)


def generate(params):
    return ic.build("fight", [ic.layer(sword(40.0), ic.ICON), ic.layer(sword(-40.0), ic.ICON)])
