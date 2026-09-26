"""unit_defs `fusion_reactor`: the tier-1 fusion reactor (see shared/reactor.py)."""

from .shared import reactor

CATEGORY = "entity"
DEF = "fusion_reactor"


def generate(params):
    return reactor.generate(params, tier=1)
