"""unit_defs `epic_fusion_reactor`: 3-tier fusion reactor, 5x5x5 cells (20x20x20 studs). See reactor_common.py."""

from . import reactor_common


def generate(params):
    params.setdefault("width", 20.0)
    params.setdefault("depth", 20.0)
    params.setdefault("height", 20.0)
    return reactor_common.generate(params, tier=3)
