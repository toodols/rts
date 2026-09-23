"""unit_defs `scavenger_beacon`: 3x4x3 cells (12 wide, 16 tall, 12 long), scavenger purple. See beacon_common.py."""

from . import beacon_common


def generate(params):
    params.setdefault("width", 12.0)
    params.setdefault("height", 16.0)
    return beacon_common.generate(params, sea=False)
