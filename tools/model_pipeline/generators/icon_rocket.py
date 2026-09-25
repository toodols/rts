"""HUD icon: unguided rockets, a stubby rocket with fins flying up and to the right on a flame. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    flame = ic.teardrop(0.0, -1.45, 0.36, 1.05, angle=-90.0)
    fins = [
        ic.poly(((-0.42, -0.2), (-0.42, -1.0), (-0.95, -1.4), (-0.95, -0.78))),
        ic.poly(((0.42, -0.2), (0.95, -0.78), (0.95, -1.4), (0.42, -1.0))),
    ]
    body = ic.rect(-0.43, -1.05, 0.43, 0.75)
    nose = ic.poly(((-0.43, 0.75), (0.43, 0.75), (0.37, 1.1), (0.2, 1.42), (0.0, 1.6), (-0.2, 1.42), (-0.37, 1.1)))
    shift, angle = (0.0, 0.42), -45.0
    return ic.build(
        "rocket",
        [
            ic.layer(ic.place([flame] + fins, shift, angle), ic.ICON),
            ic.layer(ic.place([body], shift, angle), ic.ICON),
            ic.layer(ic.place([nose], shift, angle), ic.ICON),
        ],
    )
