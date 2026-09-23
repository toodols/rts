"""unit_defs `energy_converter`: 1-tier energy converter, 1x1x1 cells (4x4x4 studs). See converter_common.py."""

from . import converter_common


def generate(params):
    params.setdefault("width", 4.0)
    params.setdefault("depth", 4.0)
    params.setdefault("height", 4.0)
    return converter_common.generate(params, tier=1)
