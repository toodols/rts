"""HUD icon: cannons, a fat shell in flight with a dark driving band and speed lines behind. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    body = ic.poly(((-0.62, -1.25), (0.62, -1.25), (0.62, 0.35), (0.55, 0.8), (0.36, 1.2), (0.0, 1.6), (-0.36, 1.2), (-0.55, 0.8), (-0.62, 0.35)))
    band = ic.rect(-0.64, -0.95, 0.64, -0.62)
    lines = [ic.bar((x, -1.6), (x, -2.35 + abs(x) * 0.8), 0.22) for x in (-0.4, 0.0, 0.4)]
    shift, angle = (0.0, 0.35), -45.0
    return ic.build(
        "cannon",
        [
            ic.layer(ic.place(lines, shift, angle), ic.ICON),
            ic.layer(ic.place([body], shift, angle), ic.ICON),
            ic.layer(ic.place([band], shift, angle), ic.OUTLINE, rim=None),
        ],
    )
