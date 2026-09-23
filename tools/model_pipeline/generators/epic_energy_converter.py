"""unit_defs `epic_energy_converter`: 3-tier energy converter, 3x3x3 cells (12x12x12 studs). See converter_common.py."""

from . import converter_common


def generate(params):
    params.setdefault("width", 12.0)
    params.setdefault("depth", 12.0)
    params.setdefault("height", 12.0)
    return converter_common.generate(params, tier=3)
