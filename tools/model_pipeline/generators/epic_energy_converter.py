"""unit_defs `epic_energy_converter`: the tier-3 energy converter (see shared/converter.py)."""

from .shared import converter

CATEGORY = "entity"
DEF = "epic_energy_converter"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 14.16}


def generate(params):
    return converter.generate(params, tier=3)
