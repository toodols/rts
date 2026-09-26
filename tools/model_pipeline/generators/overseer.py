"""unit_defs/defense.luau `overseer` (BAR's corgate, the plasma deflector): a shield
generator, held to 100 triangles. A sloped footing carries a diamond-turned pedestal with glowing seams; four
team-coloured prongs rise from its corners and curl in round a glowing emitter crystal, which a tilted glowing ring
circles like a gyroscope.

The crystal and its ring are piece "emitter", spinning about the vertical (the tilted ring wobbles as it turns).
"""

import math

from .shared import common
from .shared import defense_b as d
from .shared import palette

CATEGORY = "entity"
DEF = "overseer"
SPIN_SPEED = 1.2  # radians a second


def generate(params):
    w, l = params["collider"]["width"], params["collider"]["length"]
    accent = params["color"]
    objects = []

    objects.append(common.trim_mat(d.block("footing", w, l, 0.7, top=(3.5, 3.5))))

    # the pedestal, turned 45 degrees so its faces look out along the diagonals
    bottom, top = 0.7, 1.6
    r0, r1 = 1.15, 0.8
    ped = d.block("pedestal", r0 * 2.0, r0 * 2.0, top - bottom, origin=(0.0, 0.0, bottom), top=(r1 * 2.0, r1 * 2.0))
    ped.rotation_euler = (0.0, 0.0, math.radians(45.0))
    objects.append(common.body_mat(ped))
    h = top - bottom
    for i in range(4):
        a = math.radians(45.0 + 90.0 * i)
        n = (math.cos(a), math.sin(a))
        fm = (r0 + r1) / 2.0 + 0.02
        along = (-n[1] * 0.5, n[0] * 0.5, 0.0)
        up = (-n[0] * (r0 - r1) * 0.09, -n[1] * (r0 - r1) * 0.09, h * 0.09)
        objects.append(common.glow_mat(d.panel("seam", (n[0] * fm, n[1] * fm, bottom + h * 0.5), along, up), palette.DEFLECTOR_BLUE))

    # prongs from the footing's corners, leaning in over the emitter
    for cx in (-1.0, 1.0):
        for cy in (-1.0, 1.0):
            objects.append(common.accent_mat(common.pyramid("prong", 0.6, 0.6, 3.25, apex=(-cx * 0.62, -cy * 0.62), origin=(cx * 1.42, cy * 1.42, 0.7), base=False), accent))

    # the emitter: a glowing crystal, circled by a tilted ring
    centre = (0.0, 0.0, 2.75)
    crystal = common.octahedron("crystal", 0.62, origin=centre)
    crystal.scale = (1.0, 1.0, 1.35)
    ring = common.band("ring", 0.95, 0.16, segments=6, origin=centre, thickness=0.08)
    ring.rotation_euler = (math.radians(24.0), 0.0, 0.0)
    for o in (crystal, ring):
        common.glow_mat(o, palette.DEFLECTOR_BLUE)
    emitter = d.merged("emitter", [crystal, ring], origin=centre)
    objects.append(common.art_group(emitter, "emitter", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=SPIN_SPEED))

    return objects
