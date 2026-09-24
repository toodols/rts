"""One of the pool skin's floats (src/shared/skins/pool.luau): an inflatable iced donut, the kind printed to look like
a real one. A doughy ring with its top half iced in the team's colour, dripping a little way down the outside here and
there. See pool_float_common for how it is laid out.
"""

from . import common
from . import pool_float_common as ring

MAX_TRIANGLES = 200
RECENTRE = False

SEGMENTS = 12
SIDES = 8  # the top half, sides 0 to 3, is iced

DOUGH_COLOR = (0.83, 0.6, 0.36, 1.0)
ICING_COLOR = (0.96, 0.45, 0.66, 1.0)


def iced(i, j):
    # a drip down the outside on every other segment, over the side just below the outer equator
    return j < SIDES // 2 or (j == SIDES - 1 and i % 2 == 0)


def generate(params):
    icing = ring.ring("icing", SEGMENTS, SIDES, iced)
    common.apply_material(icing, "pool_donut_iced_accent", ICING_COLOR, roughness=0.25)
    dough = ring.ring("dough", SEGMENTS, SIDES, lambda i, j: not iced(i, j))
    common.apply_material(dough, "pool_donut_iced_dough", DOUGH_COLOR, roughness=0.35)
    return [icing, dough]
