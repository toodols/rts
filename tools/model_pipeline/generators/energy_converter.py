"""unit_defs `energy_converter`: the tier-1 energy converter (see shared/converter.py)."""

from .shared import converter

CATEGORY = "entity"
DEF = "energy_converter"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 4.72}


def generate(params):
    return converter.generate(params, tier=1)
