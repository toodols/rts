"""unit_defs `twin_guard` (corhllt): a laser tower with two independent turrets stacked on one
column -- a long-barreled head on top and a wide, short-barreled ring turret below it, at the
weapons' offsets (0, 3, 0) and (0, 1, 0)."""

from . import tower_common


def generate(params):
    return tower_common.generate(params, tier="twin_guard")
