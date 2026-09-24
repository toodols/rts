"""Tutorial UI icon: a chunky red X ("not allowed"), bright red over a dark red rim, standing up in the XY plane
(Roblox) and facing +Z. The origin is its middle. Everything is `base`. Written to src/shared/ui_art/.
"""

import math

from . import tutorial_common as tc

MAX_TRIANGLES = tc.MAX_TRIANGLES
RECENTRE = False

FILL_COLOR = (0.90, 0.18, 0.16, 1.0)
RIM_COLOR = (0.38, 0.04, 0.04, 1.0)


def generate(params):
    w = params.get("half_thickness", 0.32)
    arm = params.get("arm", 1.5)
    plus = (
        (w, arm), (-w, arm), (-w, w), (-arm, w), (-arm, -w), (-w, -w),
        (-w, -arm), (w, -arm), (w, -w), (arm, -w), (arm, w), (w, w),
    )
    c = s = math.sqrt(0.5)
    polygon = [(x * c - y * s, x * s + y * c) for x, y in plus]
    return tc.outlined_badge("cross", polygon, FILL_COLOR, RIM_COLOR, rim=0.14, depth=0.4)
