"""unit_defs `advanced_fusion_reactor`: the tier-2 fusion reactor (see shared/reactor.py)."""

from .shared import reactor

CATEGORY = "entity"
DEF = "advanced_fusion_reactor"


def generate(params):
    return reactor.generate(params, tier=2)
