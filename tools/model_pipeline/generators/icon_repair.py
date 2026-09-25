"""HUD icon: the Repair order, an open-ended wrench. Written to src/shared/ui_art/ (see icon_common)."""

import math

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def generate(params):
    cx, r, gap = 1.15, 0.8, 0.28
    a = math.degrees(math.asin(gap / r))
    head = ic.poly(ic.arc_points(cx, 0.0, r, a, 360.0 - a, 16) + [(cx + 0.05, -gap), (cx + 0.05, gap)])
    handle = ic.rounded_rect(-1.95, -0.3, 0.7, 0.3, 0.28, 3)
    return ic.build("repair", [ic.layer(ic.place([handle, head], shift=(0.05, 0.0), angle=45.0), ic.ICON)])
