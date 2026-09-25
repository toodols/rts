"""HUD icon: a lightning gun, a bolt. Written to src/shared/ui_art/ (see icon_common)."""

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    bolt = ic.poly(ic.BOLT)
    return ic.build("lightning", [ic.layer([bolt], ic.ICON)])
