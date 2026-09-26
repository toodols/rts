"""One of the pool skin's floats (src/shared/skins/pool.luau): a lifebuoy. A white ring with four narrow bands of the
team's colour round it, a quarter turn apart. See shared/pool_float for how it is laid out.
"""

from .shared import common
from .shared import palette
from .shared import pool_float as ring

CATEGORY = "prop"
SKIN = "pool"
SEGMENTS = 16
SIDES = 6
BANDS = 4


def banded(i, _j):
    return i % (SEGMENTS // BANDS) == 0


def generate(params):
    bands = ring.ring("bands", SEGMENTS, SIDES, banded)
    common.accent_mat(bands, palette.LIFEBUOY_RED)
    white = ring.ring("white", SEGMENTS, SIDES, lambda i, j: not banded(i, j))
    common.paint(white, palette.FLOAT_WHITE)
    return [bands, white]
