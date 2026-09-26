"""unit_defs `epic_fusion_reactor`: the tier-3 fusion reactor (see shared/reactor.py)."""

from .shared import reactor

CATEGORY = "entity"
DEF = "epic_fusion_reactor"


def generate(params):
    return reactor.generate(params, tier=3)
