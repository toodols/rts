"""unit_defs.luau `construction_turret`: a 1x1x1 cell (4x4x4 stud) stationary builder.

Params (all optional): width, depth, height (studs, default 4/4/4), body_color, accent_color,
glass_color (RGBA 0-1 lists). See turret_common.py for the shared geometry.
"""

from . import turret_common


def generate(params):
    return turret_common.generate(params, advanced=False)
