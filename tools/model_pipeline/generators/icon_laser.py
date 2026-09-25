"""HUD icon: lasers, a beam with a flare where it hits. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    start, hit = (-1.72, -1.72), (1.05, 1.05)
    return ic.build(
        "laser",
        [
            ic.layer([ic.bar(start, hit, 0.72), ic.star(hit[0], hit[1], 0.95, 0.4, points=8, angle=0.0)], ic.ICON),
            ic.layer([ic.star(hit[0], hit[1], 0.5, 0.22, points=8, angle=22.5)], ic.ICON),
        ],
    )
