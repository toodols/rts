"""unit_defs `tree`: a fir, reclaimed for energy, strewn over a map by the thousand (see shared/reclaimable.py).

An open six-sided trunk and a crown of three six-sided tiers, each turned a little from the one below, as the old
four-part tree was (a trunk and three tiers). Two meshes, bark and needles, where it used to be four Parts. The server
stretches it to its collider, 20 x 60 x 20 elmos, so only its proportions matter here.
"""

import math

from .shared import common
from .shared import palette
from .shared import reclaimable

CATEGORY = "reclaimable"
DEF = "tree"

HEIGHT = 3.0
RADIUS = 0.5
TRUNK_HEIGHT = HEIGHT * 0.3


def generate(params):
    trunk = reclaimable.frustum("trunk", RADIUS * 0.2, RADIUS * 0.14, TRUNK_HEIGHT + 0.2)
    common.paint(trunk, palette.TREE_TRUNK)

    # three tiers, each narrower and higher, overlapping the one below; only the lowest shows its underside
    tiers = []
    crown = HEIGHT - TRUNK_HEIGHT
    for tier in range(3):
        width = 1.0 - tier * 0.28
        tier_height = crown * (0.52 - tier * 0.06)
        z = TRUNK_HEIGHT + crown * tier * 0.3
        if tier == 2:
            tier_height = HEIGHT - z
        obj = reclaimable.cone(
            f"tier_{tier}", RADIUS * width, tier_height, z=z, turn=tier * math.pi / 6, base=tier == 0
        )
        common.paint(obj, params["color"])
        tiers.append(obj)
    return [trunk] + tiers
