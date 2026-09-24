"""One of the pool skin's floats (src/shared/skins/pool.luau): a lifebuoy. A white ring with four narrow bands of the
team's colour round it, a quarter turn apart. See pool_float_common for how it is laid out.
"""

from . import common
from . import pool_float_common as ring

MAX_TRIANGLES = 200
RECENTRE = False

SEGMENTS = 16
SIDES = 6
BANDS = 4

BAND_COLOR = (0.9, 0.2, 0.18, 1.0)
WHITE_COLOR = (0.96, 0.96, 0.94, 1.0)


def banded(i, _j):
    return i % (SEGMENTS // BANDS) == 0


def generate(params):
    bands = ring.ring("bands", SEGMENTS, SIDES, banded)
    common.apply_material(bands, "pool_lifebuoy_accent", BAND_COLOR, roughness=0.3)
    white = ring.ring("white", SEGMENTS, SIDES, lambda i, j: not banded(i, j))
    common.apply_material(white, "pool_lifebuoy_white", WHITE_COLOR, roughness=0.3)
    return [bands, white]
