"""HUD icon: EMP (paralyser) weapons, a bolt sending out pulses on both sides. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    bolt = ic.transform(ic.poly(ic.BOLT), scale=0.55)
    pulses = []
    for r in (1.05, 1.6):
        pulses.append(ic.arc_band(0.0, 0.0, r, r + 0.32, -42.0, 42.0, 8))
        pulses.append(ic.arc_band(0.0, 0.0, r, r + 0.32, 138.0, 222.0, 8))
    return ic.build("emp", [ic.layer(pulses, palette.ICON_FILL), ic.layer([bolt], palette.ICON_FILL)])
