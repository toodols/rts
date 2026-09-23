"""unit_defs.luau `guard`: a laser tower with one turret (a plain `weapon`, not `turrets`)."""

from . import tower_common


def generate(params):
    return tower_common.generate(params, tier="guard")
