"""unit_defs `fusion_reactor`: 1-tier fusion reactor, 3x3x3 cells (12x12x12 studs). See reactor_common.py."""

from . import reactor_common


def generate(params):
    params.setdefault("width", 12.0)
    params.setdefault("depth", 12.0)
    params.setdefault("height", 12.0)
    return reactor_common.generate(params, tier=1)
