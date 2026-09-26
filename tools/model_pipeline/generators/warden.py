"""unit_defs.luau `warden`: a taller, heavier tower with one heavy laser turret."""

from .shared import tower

CATEGORY = "entity"
DEF = "warden"
MOUNTS = {
    1: {"pivot": (0, 4.9, 0), "muzzle": (0, 0.75, 3.64)},
}


def generate(params):
    return tower.generate(
        params,
        column_top=4.9,
        plinth_height=1.3,
        column_width=1.6,
        heads=[{"width": 2.5, "length": 2.7, "height": 1.5, "barrel": 0.45, "barrel_len": 2.2, "heavy": True}],
    )
