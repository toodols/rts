"""unit_defs.luau `construction_turret`: a stationary builder with one nanolathe arm (see shared/turret.py)."""

from .shared import turret

CATEGORY = "entity"
DEF = "construction_turret"


def generate(params):
    return turret.generate(params, column_top=2.1, head=(1.6, 1.7, 0.9), reach=2.2, arms=(0.0,))
