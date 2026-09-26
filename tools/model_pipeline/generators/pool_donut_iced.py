"""One of the pool skin's floats (src/shared/skins/pool.luau): an inflatable iced donut, the kind printed to look like
a real one. A doughy ring with its top half iced in the team's colour, dripping a little way down the outside here and
there. See shared/pool_float for how it is laid out.
"""

from .shared import common
from .shared import palette
from .shared import pool_float as ring

CATEGORY = "prop"
SKIN = "pool"
SEGMENTS = 12
SIDES = 8  # the top half, sides 0 to 3, is iced


def iced(i, j):
    # a drip down the outside on every other segment, over the side just below the outer equator
    return j < SIDES // 2 or (j == SIDES - 1 and i % 2 == 0)


def generate(params):
    icing = ring.ring("icing", SEGMENTS, SIDES, iced)
    common.accent_mat(icing, palette.ICING)
    dough = ring.ring("dough", SEGMENTS, SIDES, lambda i, j: not iced(i, j))
    common.paint(dough, palette.DOUGH)
    return [icing, dough]
