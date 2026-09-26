"""unit_defs `shrub`: a fern or a clump of mushrooms, as BAR's maps strew them, reclaimed for a little energy.

Three low, rough lumps of leaves in one mesh, where it used to be two Parts. The server stretches it to its collider,
24 x 16 x 24 elmos, so only its proportions matter here.
"""

import random

from .shared import common
from .shared import reclaimable

CATEGORY = "reclaimable"
DEF = "shrub"


def generate(params):
    rng = random.Random(params.get("seed", 3))
    # the first, the biggest, is the footprint the model is centred on
    lumps = [
        reclaimable.lump("clump", (0.95, 0.8, 0.62), (0.0, 0.0, 0.1), rng, 0.18),
        reclaimable.lump("clump_e", (0.55, 0.5, 0.45), (0.55, 0.35, 0.0), rng, 0.2),
        reclaimable.lump("clump_w", (0.5, 0.55, 0.4), (-0.5, -0.4, 0.0), rng, 0.2),
    ]
    for obj in lumps:
        common.paint(obj, params["color"])
    return lumps
