"""unit_defs.luau `metal_storage`: 2x2x2 cells (8x8x8 studs), steel silo (see storage_common.py)."""

from . import storage_common


def generate(params):
    params.setdefault("width", 8.0)
    params.setdefault("depth", 8.0)
    params.setdefault("height", 8.0)
    return storage_common.generate(params, kind="metal")
