"""unit_defs.luau `energy_storage`: a gold capacitor drum (see shared/storage.py)."""

from .shared import storage

CATEGORY = "entity"
DEF = "energy_storage"


def generate(params):
    return storage.capacitor(params, hardened=False)
