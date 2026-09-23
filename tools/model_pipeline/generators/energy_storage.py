"""unit_defs.luau `energy_storage`: 1x1x1 cells (4x4x4 studs), gold capacitor drum (see storage_common.py)."""

from . import storage_common


def generate(params):
    params.setdefault("width", 4.0)
    params.setdefault("depth", 4.0)
    params.setdefault("height", 4.0)
    return storage_common.generate(params, kind="energy")
