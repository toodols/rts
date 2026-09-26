"""unit_defs `slingshot` (corfrt): the Thistle afloat, a light anti-air missile tower. Under 100 triangles.

A six-sided float hull, and on its deck the Thistle's tapered column, shorter, topped by the Thistle's missile
yoke: a small armored cab between two four-cell missile pods, pitched steeply up. The whole head yaws with weapon 1.
"""

import math

from .shared import defense_a as d
from .shared import sea_defense as sea

CATEGORY = "entity"
DEF = "slingshot"
MOUNTS = {
    1: {"pivot": (0, 3.4, 0), "muzzle": (-0.53, 1.3665, 0.9706)},
}
SWIVEL_Z = 3.4
POD_ELEV = 42.0


def generate(params):
    w = params["collider"]["width"]
    base = d.Parts()
    # a six-sided hull, to keep within its budget beside the Thistle's head, and the column rising from its deck
    # sized so its corners, not its flats, fit the footprint
    deck = sea.hull(base, (w - 0.1) * math.cos(math.pi / 6.0), sides=6)
    base.loft([d.square(1.5, deck), d.square(1.1, SWIVEL_Z)], side="body")

    head = d.Parts()
    fr = d.Frame()
    # the Thistle's cab: a sloped glacis in front, a dark power block behind
    head.block_u(fr, 0.0, 0.05, 0.0, 1.2, (1.1, 1.6), (0.8, 1.0), top_shift_f=-0.2,
                 tags={"all": "accent", "bottom": None})
    head.block_u(fr, 0.0, -0.95, 0.1, 0.85, (0.8, 0.5), (0.7, 0.4), tags={"all": "trim", "bottom": None, "fore": None})
    for side in (-1.0, 1.0):
        pod = d.Frame(origin=(side * 0.84, 0.0, 0.95), elev=POD_ELEV)
        # a launcher box narrowing a little to its dark front face, four lit tube mouths on it
        head.block_f(pod, 0.0, 0.0, -0.95, 1.0, (0.72, 0.8), (0.62, 0.68), tags={"all": "accent", "front": "trim"})
        # a dark clamp band round the pod
        head.block_f(pod, 0.0, 0.0, -0.3, -0.1, (0.78, 0.86), tags={"all": "trim", "back": None, "front": None})
        for x in (-0.15, 0.15):
            for u in (-0.16, 0.16):
                head.quad_f(pod, x, 1.005, u, 0.17, 0.17)

    objects = d.base_objects(base, "trim", params["color"])
    objects += d.head_objects(head, (0.0, 0.0, SWIVEL_Z), params["color"])
    return objects
