"""unit_defs.luau `metal_storage`: a steel silo (see shared/storage.py)."""

from .shared import storage

CATEGORY = "entity"
DEF = "metal_storage"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"width": 8.24}


def generate(params):
    return storage.silo(params)
