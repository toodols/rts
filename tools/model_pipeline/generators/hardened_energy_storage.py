"""unit_defs.luau `hardened_energy_storage`: 2x2x2 cells (8x8x8 studs), the "advanced" energy
storage -- the same gold capacitor as energy_storage, wrapped in sloped armor (see storage_common.py)."""

from . import storage_common


def generate(params):
    params.setdefault("width", 8.0)
    params.setdefault("depth", 8.0)
    params.setdefault("height", 8.0)
    return storage_common.generate(params, kind="energy", hardened=True)
