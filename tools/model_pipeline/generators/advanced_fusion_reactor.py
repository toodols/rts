"""unit_defs `advanced_fusion_reactor`: 2-tier fusion reactor, 4x4x4 cells (16x16x16 studs). See reactor_common.py."""

from . import reactor_common


def generate(params):
    params.setdefault("width", 16.0)
    params.setdefault("depth", 16.0)
    params.setdefault("height", 16.0)
    return reactor_common.generate(params, tier=2)
