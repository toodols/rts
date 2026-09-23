"""unit_defs.luau `hardened_metal_storage`: 2x1x2 cells (8x4x8 studs), the "advanced" metal
storage -- a squat armored bunker rather than metal_storage's silo (see storage_common.py)."""

from . import storage_common


def generate(params):
    params.setdefault("width", 8.0)
    params.setdefault("depth", 8.0)
    params.setdefault("height", 4.0)
    return storage_common.generate(params, kind="metal", hardened=True)
