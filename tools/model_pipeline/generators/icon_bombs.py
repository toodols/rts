"""HUD icon: bombs, an aerial bomb falling nose first, with motion lines. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    body = ic.teardrop(0.0, -0.6, 0.86, 2.2, angle=90.0, segments=16)
    fins = ic.poly(((-0.78, 1.95), (0.78, 1.95), (0.44, 0.95), (-0.44, 0.95)))
    lines = [ic.bar((-1.5, 0.25), (-1.5, 1.55), 0.24), ic.bar((1.5, 0.25), (1.5, 1.55), 0.24), ic.bar((-1.85, -0.75), (-1.85, 0.05), 0.2), ic.bar((1.85, -0.75), (1.85, 0.05), 0.2)]
    shift, angle = (0.0, -0.05), 15.0
    return ic.build(
        "bombs",
        [
            ic.layer(ic.place(lines, shift, angle), ic.ICON),
            ic.layer(ic.place([fins, body], shift, angle), ic.ICON),
        ],
    )
