"""unit_defs `scavenger_sea_beacon`: the scavengers' beacon at sea, which floats (see shared/beacon.py)."""

from .shared import beacon

CATEGORY = "entity"
DEF = "scavenger_sea_beacon"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 12.8, "height": 16.6}


def generate(params):
    return beacon.generate(params, sea=True)
