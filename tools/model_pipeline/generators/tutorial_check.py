"""Tutorial UI icon: a chunky green check mark ("allowed"), bright green over a dark green rim, standing up in the
XY plane (Roblox) and facing +Z. The origin is the middle of its bounds. Everything is `base`. Written to
src/shared/ui_art/.
"""

from . import tutorial_common as tc

MAX_TRIANGLES = tc.MAX_TRIANGLES
RECENTRE = False

FILL_COLOR = (0.22, 0.80, 0.30, 1.0)
RIM_COLOR = (0.04, 0.30, 0.08, 1.0)

# in (x, up): the short arm down to the bottom point, the long arm up to the right, both about 0.64 thick
CHECK = ((-1.1, 0.5), (-1.55, 0.05), (-0.55, -0.95), (1.6, 1.2), (1.15, 1.65), (-0.55, -0.05))


def generate(params):
    polygon = tc.ccw(CHECK)
    xs = [p[0] for p in polygon]
    ys = [p[1] for p in polygon]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    polygon = [(x - cx, y - cy) for x, y in polygon]
    return tc.outlined_badge("check", polygon, FILL_COLOR, RIM_COLOR, rim=0.14, depth=0.4)
