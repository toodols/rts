"""unit_defs.luau `advanced_construction_turret`: a 1x2x1 cell (4x8x4 stud) stationary builder.

Params (all optional): width, depth, height (studs, default 4/4/8), body_color, accent_color,
glass_color (RGBA 0-1 lists). See turret_common.py for the shared geometry -- the extra height
over the basic turret goes into a second arm and a mast/dish.
"""

from . import turret_common


def generate(params):
    return turret_common.generate(params, advanced=True)
