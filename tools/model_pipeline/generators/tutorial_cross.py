"""Tutorial UI icon: a chunky red X ("not allowed"), bright red over a dark red rim, standing up in the XY plane
(Roblox) and facing +Z. The origin is its middle. Everything is `base`. Written to src/shared/ui_art/.
"""

import math

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    w = params.get("half_thickness", 0.32)
    arm = params.get("arm", 1.5)
    plus = (
        (w, arm), (-w, arm), (-w, w), (-arm, w), (-arm, -w), (-w, -w),
        (-w, -arm), (w, -arm), (w, -w), (arm, -w), (arm, w), (w, w),
    )
    c = s = math.sqrt(0.5)
    polygon = [(x * c - y * s, x * s + y * c) for x, y in plus]
    return ic.badge("cross", polygon, palette.CROSS_FILL, palette.CROSS_RIM, rim=0.14, depth=0.4)
