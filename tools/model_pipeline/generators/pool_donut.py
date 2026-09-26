"""The pool skin's pool donut (src/shared/skins/pool.luau): an inflatable swim ring, worn round a unit's waist.

A fat vinyl ring striped in the team's colour and white, with a little valve on top. It lies flat in the ground plane,
its hole straight up, and its origin is its very middle (not the ground: it is never stood on anything), with the ring
1 unit out and the tube pool_float.TUBE across it either way; client/donuts.luau scales it to the unit wearing it. Everything is
one static piece. The team-coloured stripes are its accent, so they take the team's colour.
"""

import math

from .shared import common
from .shared import palette
from .shared import pool_float as ring

CATEGORY = "prop"
SKIN = "pool"
# it is worn by every unit at once, so it is kept small, if a little over a unit's usual budget, to stay round
SEGMENTS = 12  # round the ring
SIDES = 6  # round the tube
STRIPES = 6  # alternating team-coloured and white, SEGMENTS / STRIPES segments each


def striped(i, _j):
    """Whether segment i is in a team-coloured stripe."""
    return (i // (SEGMENTS // STRIPES)) % 2 == 0


def generate(params):
    accent = ring.ring("stripes_accent", SEGMENTS, SIDES, striped)
    common.accent_mat(accent, palette.DONUT_RED)
    white = ring.ring("stripes_white", SEGMENTS, SIDES, lambda i, j: not striped(i, j))
    common.paint(white, palette.FLOAT_WHITE)

    # the valve, on top of the tube halfway through a white stripe
    per = SEGMENTS // STRIPES
    a = 2.0 * math.pi * (per + per / 2) / SEGMENTS
    valve = common.cylinder(
        "valve", ring.TUBE * 0.16, ring.TUBE * 0.22, origin=(ring.RING * math.cos(a), ring.RING * math.sin(a), ring.TUBE * 0.98), segments=6
    )
    common.paint(valve, palette.DONUT_VALVE)
    return [accent, white, valve]
