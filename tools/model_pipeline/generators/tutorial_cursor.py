"""Tutorial UI icon: the classic arrow mouse pointer, white with a dark rim, standing up in the XY plane (Roblox) and
facing +Z, its tip up and to the left.

Its tip (the rim's point) is exactly the origin, so the pointer can be placed by where it points; the rest of it
hangs down and to the right (+X, -Y). One art group, `pointer` (rim and fill). Written to src/shared/ui_art/.
"""

from .shared import icon as ic
from .shared import palette
from .shared import polygons

CATEGORY = "hud"

# the pointer in (x, up), in "pixels" with its tip at the origin: down the left edge, the notch, the tail, the wing
ARROW = ((0.0, 0.0), (0.0, -16.0), (3.7, -12.5), (6.6, -18.6), (9.3, -17.4), (6.4, -11.4), (11.2, -11.4))


def generate(params):
    scale = params.get("scale", 0.18)
    polygon = polygons.ccw([(x * scale, y * scale) for x, y in ARROW])
    rim = params.get("rim", 0.14)
    # put the rim's tip, not the white's, on the origin
    tip = polygons.offset(polygon, rim, max_miter=3.0)[polygon.index((0.0, 0.0))]
    polygon = [(x - tip[0], y - tip[1]) for x, y in polygon]
    return ic.badge("cursor", polygon, palette.CURSOR_FILL, palette.INK, rim=rim, depth=0.36, group="pointer")
