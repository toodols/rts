"""unit_defs.luau `hardened_energy_storage`: the "advanced" energy storage -- the same capacitor as
energy_storage, wrapped in sloped armor (see shared/storage.py)."""

from .shared import storage

CATEGORY = "entity"
DEF = "hardened_energy_storage"


def generate(params):
    return storage.capacitor(params, hardened=True)
