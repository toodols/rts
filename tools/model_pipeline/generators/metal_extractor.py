"""unit_defs `metal_extractor` (cormex): 1x1x1 cell (4x4x4 studs), steel accent. It stands on a metal spot.
Budget: 100 triangles.

A squat drill rig: a sloped hexagonal gunmetal base braced by three dark claws, a glowing ring of molten ore
where the bore comes up through it, a dark bore column, and on top the spinning drill head -- a steel hub and
cap with three swept arms, turning about the vertical like cormex's. The head is its own rigid piece
(common.art_group, kind="spin"), pivoting on the column's axis.
"""

import math

from . import common
from . import economy_common as eco


def generate(params):
    w = float(params.get("width", 4.0))
    s = w / 4.0
    objects = []

    base_h = 0.8 * s
    base = eco.Mesh().frustum(eco.ngon(2.15 * s, 6), eco.ngon(1.5 * s, 6), 0.0, base_h)
    objects.append(eco.body(base.build("base")))

    ring = eco.Mesh().poly(eco.at(eco.ngon(1.2 * s, 6, math.pi / 6), base_h + 0.01 * s))
    objects.append(eco.glow(ring.build("ore_ring"), "mex", eco.ORE_GLOW, emission=1.0))

    dark = eco.Mesh()
    col_top = base_h + 0.95 * s
    dark.frustum(eco.ngon(0.85 * s, 6, math.pi / 6), eco.ngon(0.62 * s, 6, math.pi / 6), base_h, col_top, cap_top=False)
    for i in range(3):
        eco.wedge(dark, math.radians(90.0 + 120.0 * i), 0.8 * s, 2.2 * s, 0.45 * s, 0.0, 1.75 * s)
    objects.append(eco.trim(dark.build("column")))

    # The drill head, pivoting on the column's axis at its top.
    hub_z = col_top
    head = eco.Mesh()
    hub_top = hub_z + 0.45 * s
    head.frustum(eco.ngon(0.75 * s, 6), eco.ngon(0.6 * s, 6), hub_z, hub_top, cap_top=False)
    head.pyramid(eco.at(eco.ngon(0.6 * s, 6), hub_top), (0.0, 0.0, hub_top + 0.5 * s))
    arm_bottom = eco.rect(0.55 * s, 1.35 * s, (0.0, 0.0))
    arm_top = eco.rect(0.4 * s, 1.25 * s, (0.0, 0.0))
    for i in range(3):
        a = math.radians(30.0 + 120.0 * i)
        # swept a little, like a rotor blade, and drooping at the tip
        m = eco.matrix((math.cos(a) * 1.1 * s, math.sin(a) * 1.1 * s, hub_z + 0.05 * s), (math.radians(-6.0), 0.0, a - math.pi / 2 + math.radians(14.0)))
        head.frustum(arm_bottom, arm_top, 0.0, 0.32 * s, m=m, cap_bottom=True, skip=(0,))
    drill = eco.accent(head.build("drill_head", location=(0.0, 0.0, hub_z)), "mex", eco.STEEL)
    objects.append(common.art_group(drill, "drill", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=1.6))

    return objects
