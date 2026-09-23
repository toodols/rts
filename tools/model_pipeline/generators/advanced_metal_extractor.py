"""unit_defs `advanced_metal_extractor` (cormoho): 1x1x1 cell (4x4x4 studs), steel accent. It stands on a metal
spot, often on top of a plain extractor's. Budget: 100 triangles.

The plain extractor's big brother, square and heavy where that one is hexagonal and light: a sloped square
armored base, four dark buttresses on the diagonals bracing a tall steel pump tower whose faces are slit with
glowing ore, an exhaust stack at the back, and on top a square drum crossed by two heavy cutter bars under a steel crown,
spinning about the vertical (common.art_group, kind="spin").
"""

import math

from . import common
from . import economy_common as eco


def generate(params):
    w = float(params.get("width", 4.0))
    s = w / 4.0
    objects = []

    base_h = 0.85 * s
    base = eco.Mesh().frustum(eco.rect(3.95 * s, 3.95 * s), eco.rect(3.1 * s, 3.1 * s), 0.0, base_h)
    objects.append(eco.body(base.build("base")))

    tower_top = base_h + 1.6 * s
    tb, tt = 2.1 * s, 1.6 * s
    tower = eco.Mesh().frustum(eco.rect(tb, tb), eco.rect(tt, tt), base_h, tower_top, cap_top=False)
    objects.append(eco.accent(tower.build("tower"), "moho", eco.STEEL))

    # Ore slits: one glowing strip on each of the tower's sloped faces, standing just proud of it.
    slits = eco.Mesh()
    h = tower_top - base_h
    slope = math.atan2((tb - tt) / 2.0, h)
    for i in range(4):
        a = math.radians(90.0 * i)
        # a face whose outward normal is local +Y at angle a, leaning in by `slope`
        m = eco.matrix((math.cos(a) * (tb / 2 + 0.02 * s), math.sin(a) * (tb / 2 + 0.02 * s), base_h), (0.0, 0.0, a - math.pi / 2)) @ eco.matrix(rotation=(slope, 0.0, 0.0))
        z0, z1, hw = h * 0.2, h * 0.8, 0.14 * s
        slits.poly([(hw, 0.0, z0), (-hw, 0.0, z0), (-hw, 0.0, z1), (hw, 0.0, z1)], m=m)
    objects.append(eco.glow(slits.build("ore_slits"), "moho", eco.ORE_GLOW, emission=1.0))

    dark = eco.Mesh()
    for i in range(4):
        eco.wedge(dark, math.radians(45.0 + 90.0 * i), 1.0 * s, 2.55 * s, 0.5 * s, 0.0, 2.0 * s)
    # exhaust stack at the back (+Y), on the right
    dark.frustum(eco.rect(0.5 * s, 0.5 * s, (0.95 * s, 1.1 * s)), eco.rect(0.4 * s, 0.4 * s, (0.95 * s, 1.1 * s)), base_h - 0.2 * s, base_h + 2.5 * s)
    objects.append(eco.trim(dark.build("buttresses")))

    # The spinning drum, pivoting on the tower's axis at its top.
    dz = tower_top
    head = eco.Mesh()
    d0, d1 = 1.9 * s, 1.6 * s
    top = dz + 0.6 * s
    head.frustum(eco.rect(d0, d0), eco.rect(d1, d1), dz, top, cap_top=False)
    head.pyramid(eco.at(eco.rect(d1, d1), top), (0.0, 0.0, top + 0.5 * s))
    # a heavy cross of cutter bars across the drum, turned off the tower's faces
    for k in range(2):
        m = eco.matrix((0.0, 0.0, dz + 0.1 * s), (0.0, 0.0, math.radians(45.0 + 90.0 * k)))
        head.frustum(eco.rect(0.55 * s, 4.1 * s), eco.rect(0.4 * s, 3.8 * s), 0.0, 0.4 * s, m=m)
    drum = eco.accent(head.build("drum", location=(0.0, 0.0, dz)), "moho", eco.STEEL)
    objects.append(common.art_group(drum, "drill", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=2.2))

    return objects
