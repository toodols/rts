"""Tutorial UI icon: a chunky green check mark ("allowed"), bright green over a dark green rim, standing up in the
XY plane (Roblox) and facing +Z. The origin is the middle of its bounds. Everything is `base`. Written to
src/shared/ui_art/.
"""

from .shared import icon as ic
from .shared import palette
from .shared import polygons

CATEGORY = "hud"

# in (x, up): the short arm down to the bottom point, the long arm up to the right, both about 0.64 thick
CHECK = ((-1.1, 0.5), (-1.55, 0.05), (-0.55, -0.95), (1.6, 1.2), (1.15, 1.65), (-0.55, -0.05))


def generate(params):
    polygon = polygons.ccw(CHECK)
    xs = [p[0] for p in polygon]
    ys = [p[1] for p in polygon]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    polygon = [(x - cx, y - cy) for x, y in polygon]
    return ic.badge("check", polygon, palette.CHECK_FILL, palette.CHECK_RIM, rim=0.14, depth=0.4)
