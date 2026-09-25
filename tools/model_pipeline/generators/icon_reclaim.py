"""HUD icon: the Reclaim order, three arrows chasing one another round (recycling). Written to src/shared/ui_art/ (see icon_common)."""

import math

from . import icon_common as ic

MAX_TRIANGLES = ic.MAX_TRIANGLES
RECENTRE = False

def arrow(a0, a1, r_in=0.78, r_out=1.42, head=0.36, lead=32.0):
    mid = (r_in + r_out) / 2

    def at(r, a):
        return (r * math.cos(math.radians(a)), r * math.sin(math.radians(a)))

    outer = ic.arc_points(0.0, 0.0, r_out, a0, a1, 8)
    inner = list(reversed(ic.arc_points(0.0, 0.0, r_in, a0, a1, 8)))
    return ic.poly(outer + [at(r_out + head, a1), at(mid, a1 + lead), at(r_in - head, a1)] + inner)


def generate(params):
    arrows = [arrow(k * 120.0 + 12.0, k * 120.0 + 78.0) for k in range(3)]
    return ic.build("reclaim", [ic.layer(arrows, ic.ICON)])
