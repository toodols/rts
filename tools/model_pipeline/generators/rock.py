"""unit_defs `small_rock`, `rock` and `large_rock`: a metal rock, reclaimed for metal, strewn over a map by the thousand.

One mesh for all three (the server stretches it to each one's collider, 16 elmos high and 16 to 64 across), so every
rock on the map is the same MeshPart: a craggy stone and two chips at its foot, where it used to be two Parts.
"""

import random

from .shared import common
from .shared import reclaimable

CATEGORY = "reclaimable"
DEF = "rock"


def generate(params):
    rng = random.Random(params.get("seed", 11))
    # the first, the stone, is the footprint the model is centred on
    pieces = [
        reclaimable.lump("stone", (0.85, 0.7, 0.62), (0.0, 0.0, 0.36), rng, 0.22, flatten=0.35),
        reclaimable.lump("chip_e", (0.36, 0.3, 0.3), (0.72, 0.36, 0.05), rng, 0.2),
        reclaimable.lump("chip_w", (0.28, 0.32, 0.22), (-0.62, -0.5, 0.0), rng, 0.2),
    ]
    for obj in pieces:
        common.paint(obj, params["color"])
    return pieces
