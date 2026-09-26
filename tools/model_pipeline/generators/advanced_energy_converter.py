"""unit_defs `advanced_energy_converter`: the tier-2 energy converter (see shared/converter.py)."""

from .shared import converter

CATEGORY = "entity"
DEF = "advanced_energy_converter"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 9.44}


def generate(params):
    return converter.generate(params, tier=2)
