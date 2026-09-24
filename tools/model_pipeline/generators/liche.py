"""unit_defs/air_t2.luau `liche`: the atomic bomber.

Collider capsule(48, 30, 62): radius 62/22 = 2.82 studs, height 30/11 = 2.73. Faceted low-poly, under 100
triangles. A flying wing, so nothing else in the air looks like it: one broad faceted wing (the team-coloured accent)
with a sawtooth trailing edge, a raised crew hump down its middle with a dark glazed slot, two buried engines glowing at
the trailing edge, and the bomb itself hanging from the belly: a fat dark casing with a hazard-yellow band. Nothing
moves.
"""

from . import air_t1_common as air
from . import common

ACCENT = air.rgb(120, 108, 150)
RADIUS, HEIGHT = 62 / 22, 30 / 11


def generate(params):
    zc = 1.40
    objects = []

    accents = []
    # The wing: a broad arrowhead, thick in the middle, with a sawtooth trailing edge.
    accents.append(air.bipyramid("wing", [
        (0.0, -2.20, zc),
        (2.40, 0.45, zc + 0.10),
        (2.10, 0.80, zc + 0.10),
        (1.40, 0.55, zc + 0.04),
        (0.80, 1.10, zc + 0.02),
        (0.0, 0.75, zc),
        (-0.80, 1.10, zc + 0.02),
        (-1.40, 0.55, zc + 0.04),
        (-2.10, 0.80, zc + 0.10),
        (-2.40, 0.45, zc + 0.10),
    ], top=(0.0, -0.20, zc + 0.30), bottom=(0.0, -0.20, zc - 0.26)))
    for obj in accents:
        air.accent_mat(obj, "liche", ACCENT)
        objects.append(obj)

    # The crew hump down the middle.
    hump = air.loft("hump", [
        (-1.90, zc + 0.05, 0.0, 0.0),
        (-1.10, zc + 0.18, 0.46, 0.30),
        (0.40, zc + 0.14, 0.52, 0.28),
        (1.05, zc + 0.08, 0.0, 0.0),
    ], sides=4, rot=0.7854)
    common.body_mat(hump)
    objects.append(hump)

    slot = air.plate("glazing", (0.0, -1.25, zc + 0.40), (0.26, 0, 0), (0, 0.18, 0.08), (0, -0.4, 1))
    air.glass_mat(slot)
    objects.append(slot)

    glows = []
    for side in (-1.0, 1.0):
        glows.append(air.plate(f"exhaust_{side:+.0f}", (side * 0.55, 0.93, zc + 0.08), (0.24, 0, 0), (0, 0, 0.07),
                               (0, 1, 0)))
    for obj in glows:
        air.glow_mat(obj)
        objects.append(obj)

    # The bomb under the belly: a dark eight-sided casing with a pointed nose and a yellow band.
    zb = zc - 0.62
    bomb = air.loft("bomb", [
        (-1.05, zb, 0.0, 0.0),
        (-0.40, zb, 0.32, 0.32),
        (0.90, zb, 0.14, 0.14),
    ], sides=6)
    common.trim_mat(bomb)
    objects.append(bomb)
    # hazard-yellow tail fins, crossed
    for fin in (
        ((0.0, 0.55, zb + 0.10), (0.0, 1.05, zb + 0.10), (0.0, 1.00, zb + 0.42), (0.05, 0.80, zb + 0.12)),
        ((0.0, 0.55, zb - 0.10), (0.0, 1.05, zb - 0.10), (0.0, 1.00, zb - 0.42), (0.05, 0.80, zb - 0.12)),
    ):
        tail = air.tetra("bomb_fin", *fin)
        air.hivis_mat(tail)
        objects.append(tail)
    # the pylon it hangs from
    pylon = air.block("pylon", 0.14, 0.60, zc - 0.20 - (zb + 0.28), origin=(0.0, -0.05, zb + 0.28), open_bottom=True)
    common.trim_mat(pylon)
    objects.append(pylon)

    air.flat(objects)
    air.check_fit(objects, RADIUS, HEIGHT, "liche")
    return objects
