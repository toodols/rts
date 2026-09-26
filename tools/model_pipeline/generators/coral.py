"""unit_defs `coral` (corfhlt): the Warden afloat, a heavy laser tower on a broad float. Under 100 triangles.

A wide eight-sided float hull on its two-cell footprint, a dark sloped plinth on its deck, a short gunmetal column,
and on top the Warden's heavy turret (shared/tower.py), a third bigger: a sloped housing with an armored skirt and a
thick square barrel, and a glowing muzzle, which turn with weapon 1.
"""

from .shared import common
from .shared import defense_a as d
from .shared import sea_defense as sea
from .shared import tower

CATEGORY = "entity"
DEF = "coral"
# the Warden's head, a third bigger: its muzzle is the Warden's, scaled
SCALE = 1.3
SWIVEL_Z = 3.8
MOUNTS = {
    1: {"pivot": (0, 3.8, 0), "muzzle": (0, 0.975, 4.732)},
}


def generate(params):
    w = params["collider"]["width"]
    base = d.Parts()
    deck = sea.hull(base, w - 0.2)
    base.loft([d.square(4.2, deck), d.square(3.0, deck + 1.0)], side="trim", top="trim")
    base.loft([d.square(2.3, deck + 1.0), d.square(1.9, SWIVEL_Z)], side="body")
    objects = d.base_objects(base, "trim", params["color"])

    spec = {"width": 2.5, "length": 2.7, "height": 1.5, "barrel": 0.45, "barrel_len": 2.2}
    spec = {key: value * SCALE for key, value in spec.items()}
    spec["heavy"] = True
    head, glow = tower._head("turret_1", spec, SWIVEL_Z, params["color"])
    objects.append(common.art_group(head, "turret_1", pivot=True, kind="turret", weapon=1))
    objects.append(common.art_group(glow, "turret_1"))
    return objects
