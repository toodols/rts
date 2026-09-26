"""unit_defs.luau `guard`: a laser tower with one turret (a plain `weapon`, not `turrets`)."""

from .shared import tower

CATEGORY = "entity"
DEF = "guard"
MOUNTS = {
    1: {"pivot": (0, 4.7, 0), "muzzle": (0, 0.6, 2.938)},
}


def generate(params):
    return tower.generate(
        params,
        column_top=4.7,
        plinth_height=1.1,
        column_width=1.25,
        heads=[{"width": 2.0, "length": 2.3, "height": 1.2, "barrel": 0.32, "barrel_len": 1.8}],
    )
