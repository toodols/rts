"""unit_defs `scavenger_beacon`: the scavengers' beacon on land (see shared/beacon.py)."""

from .shared import beacon

CATEGORY = "entity"
DEF = "scavenger_beacon"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 12.8}


def generate(params):
    return beacon.generate(params, sea=False)
