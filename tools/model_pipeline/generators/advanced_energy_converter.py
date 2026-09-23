"""unit_defs `advanced_energy_converter`: 2-tier energy converter, 2x2x2 cells (8x8x8 studs). See converter_common.py."""

from . import converter_common


def generate(params):
    params.setdefault("width", 8.0)
    params.setdefault("depth", 8.0)
    params.setdefault("height", 8.0)
    return converter_common.generate(params, tier=2)
