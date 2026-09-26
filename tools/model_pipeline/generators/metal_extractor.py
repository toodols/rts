"""unit_defs `metal_extractor` (cormex): steel accent. It stands on a metal spot.
Budget: 100 triangles.

A squat drill rig: a sloped hexagonal gunmetal base braced by three dark claws, a glowing ring of molten ore
where the bore comes up through it, a dark bore column, and on top the spinning drill head -- a steel hub and
cap with three swept arms, turning about the vertical like cormex's. The head is its own rigid piece
(common.art_group, kind="spin"), pivoting on the column's axis.
"""

import math

from .shared import common
from .shared import economy as eco
from .shared import palette

CATEGORY = "entity"
DEF = "metal_extractor"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"width": 4.3, "length": 4.4}


def generate(params):
    accent = params["color"]
    w = params["collider"]["width"]
    s = w / 4.0
    objects = []

    base_h = 0.8 * s
    base = common.Faces().frustum(common.ngon(6, 2.15 * s), common.ngon(6, 1.5 * s), 0.0, base_h)
    objects.append(common.body_mat(base.build("base")))

    ring = common.Faces().polygon(common.at(common.ngon(6, 1.2 * s, math.pi / 6), base_h + 0.01 * s))
    objects.append(common.glow_mat(ring.build("ore_ring"), palette.MOLTEN_ORE))

    dark = common.Faces()
    col_top = base_h + 0.95 * s
    dark.frustum(common.ngon(6, 0.85 * s, math.pi / 6), common.ngon(6, 0.62 * s, math.pi / 6), base_h, col_top, cap_top=False)
    for i in range(3):
        eco.wedge(dark, math.radians(90.0 + 120.0 * i), 0.8 * s, 2.2 * s, 0.45 * s, 0.0, 1.75 * s)
    objects.append(common.trim_mat(dark.build("column")))

    # The drill head, pivoting on the column's axis at its top.
    hub_z = col_top
    head = common.Faces()
    hub_top = hub_z + 0.45 * s
    head.frustum(common.ngon(6, 0.75 * s), common.ngon(6, 0.6 * s), hub_z, hub_top, cap_top=False)
    head.pyramid(common.at(common.ngon(6, 0.6 * s), hub_top), (0.0, 0.0, hub_top + 0.5 * s))
    arm_bottom = common.rect(0.55 * s, 1.35 * s, (0.0, 0.0))
    arm_top = common.rect(0.4 * s, 1.25 * s, (0.0, 0.0))
    for i in range(3):
        a = math.radians(30.0 + 120.0 * i)
        # swept a little, like a rotor blade, and drooping at the tip
        m = eco.matrix((math.cos(a) * 1.1 * s, math.sin(a) * 1.1 * s, hub_z + 0.05 * s), (math.radians(-6.0), 0.0, a - math.pi / 2 + math.radians(14.0)))
        head.frustum(arm_bottom, arm_top, 0.0, 0.32 * s, matrix=m, cap_bottom=True, skip=(0,))
    drill = common.accent_mat(head.build_about("drill_head", (0.0, 0.0, hub_z)), accent)
    objects.append(common.art_group(drill, "drill", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=1.6))

    return objects
