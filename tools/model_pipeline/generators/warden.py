"""unit_defs.luau `warden`: a taller, heavier tower with one heavy laser turret."""

from . import tower_common


def generate(params):
    return tower_common.generate(params, tier="warden")
