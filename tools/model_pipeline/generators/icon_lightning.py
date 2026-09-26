"""HUD icon: a lightning gun, a bolt. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    bolt = ic.poly(ic.BOLT)
    return ic.build("lightning", [ic.layer([bolt], palette.ICON_FILL)])
