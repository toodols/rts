"""unit_defs `twin_guard` (corhllt): a laser tower with two independent turrets stacked on one
column -- a long-barreled head on top and a wide, short-barreled ring turret below it, at the
weapons' offsets (0, 3, 0) and (0, 1, 0)."""

from .shared import tower

CATEGORY = "entity"
DEF = "twin_guard"
MOUNTS = {
    1: {"pivot": (0, 6.1, 0), "muzzle": (0, 0.5, 3.092)},
    2: {"pivot": (0, 4.1, 0), "muzzle": (0, 0.525, 2.596)},
}


def generate(params):
    return tower.generate(
        params,
        column_top=6.1,
        plinth_height=1.1,
        column_width=1.25,
        heads=[
            {"width": 1.7, "length": 2.0, "height": 1.0, "barrel": 0.28, "barrel_len": 2.1},
            # the lower one is wide, short-barreled, and wraps the column
            {"width": 2.5, "length": 2.4, "height": 1.05, "barrel": 0.34, "barrel_len": 1.4, "swivel": 4.1},
        ],
    )
