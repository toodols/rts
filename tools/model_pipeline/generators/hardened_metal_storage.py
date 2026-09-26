"""unit_defs.luau `hardened_metal_storage`: the "advanced" metal storage -- a squat armored bunker rather
than metal_storage's silo (see shared/storage.py)."""

from .shared import storage

CATEGORY = "entity"
DEF = "hardened_metal_storage"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 8.44}


def generate(params):
    return storage.bunker(params)
