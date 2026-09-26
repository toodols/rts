"""unit_defs.luau `advanced_construction_turret`: the construction turret's upgrade, standing taller with a bigger
head and a second nanolathe arm (see shared/turret.py)."""

from .shared import turret

CATEGORY = "entity"
DEF = "advanced_construction_turret"


def generate(params):
    return turret.generate(params, column_top=4.6, head=(1.8, 1.9, 1.0), reach=2.4, arms=(0.3, -0.3))
