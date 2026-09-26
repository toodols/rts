"""HUD icon: anti-air weapons, a jet's silhouette caught in target brackets. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"
JET = ((0.0, 1.45), (0.2, 1.05), (0.24, 0.35), (1.2, -0.3), (1.2, -0.66), (0.24, -0.4), (0.22, -0.9), (0.62, -1.22), (0.62, -1.46), (0.0, -1.3))


def generate(params):
    corner = ic.poly(((1.95, 1.95), (0.9, 1.95), (0.9, 1.6), (1.6, 1.6), (1.6, 0.9), (1.95, 0.9)))
    brackets = [ic.transform(corner, angle=a) for a in (0.0, 90.0, 180.0, 270.0)]
    return ic.build("anti_air", [ic.layer(brackets, palette.ICON_FILL), ic.layer([ic.poly(ic.mirrored(JET))], palette.ICON_FILL)])
