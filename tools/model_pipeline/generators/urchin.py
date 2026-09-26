"""unit_defs `urchin` (cortl): an offshore torpedo launcher. Under 100 triangles.

It is low, as BAR's is: a float hull, and on its deck a squat eight-sided launcher dome in the team's colour with a
dark cap, bristling with dark spikes all round like its namesake, and two lit torpedo ports low on its front. It has
no turret: its torpedoes leave it whichever way their target is.
"""

import math

from .shared import common
from .shared import defense_a as d
from .shared import sea_defense as sea

CATEGORY = "entity"
DEF = "urchin"

SPIKES = 8


def generate(params):
    w = params["collider"]["width"]
    top = params["collider"]["height"]
    base = d.Parts()
    deck = sea.hull(base, w - 0.1, keel=-0.4, deck=0.3)
    # the dome: a squat eight-sided frustum with a dark cap
    r0, r1, z1 = 1.45, 0.8, top - 0.5
    base.loft([d.ngon(8, r0, deck), d.ngon(8, r1, z1)], side="accent", top="trim")
    # two lit torpedo ports on the dome's front face (-Y), low down
    fr = d.Frame(origin=(0.0, 0.0, 0.0))
    flat = r0 * math.cos(math.pi / 8)
    for x in (-0.3, 0.3):
        base.quad_f(fr, x, flat + 0.02, deck + 0.3, 0.32, 0.22)
    objects = d.base_objects(base, "trim", params["color"])

    # spikes: three-sided points leaning out from the dome's sides, between the ports' face and round the back
    spikes = common.Faces()
    mid_z = (deck + z1) / 2.0
    mid_r = (r0 + r1) / 2.0
    for i in range(SPIKES):
        a = 2.0 * math.pi * (i + 0.5) / SPIKES - math.pi / 2.0
        c, s = math.cos(a), math.sin(a)
        root = (c * mid_r * 0.9, s * mid_r * 0.9)
        # a small triangle on the dome's side, and a point out and up from it
        tangent = (-s, c)
        ring = [
            (root[0] + tangent[0] * 0.18, root[1] + tangent[1] * 0.18, mid_z - 0.12),
            (root[0] - tangent[0] * 0.18, root[1] - tangent[1] * 0.18, mid_z - 0.12),
            (root[0], root[1], mid_z + 0.2),
        ]
        spikes.pyramid(ring, (c * (mid_r + 0.75), s * (mid_r + 0.75), mid_z + 0.45))
    # and one straight up out of the cap
    cap = [(0.2, -0.2, z1), (0.2, 0.2, z1), (-0.2, 0.2, z1), (-0.2, -0.2, z1)]
    spikes.pyramid(cap, (0.0, 0.0, top - 0.02))
    objects.append(common.trim_mat(spikes.build("spikes")))
    return objects
