"""unit_defs/air_t2.luau `hailstorm`: the heavy bomber.

Faceted low-poly, under 100
triangles. The Whirlwind's big brother: a long, deep hexagonal fuselage with a glazed nose, broad swept wings (the
team-coloured accent) carrying two big engine pods, a twin tail on a wide tailplane, and a long dark bomb bay
under the belly. Nothing moves: its bombs just drop.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "hailstorm"


def generate(params):
    accent = params["color"]
    zc = 1.25
    objects = []

    body = air.loft("fuselage", [
        (-2.62, zc - 0.10, 0.0, 0.0),
        (-1.85, zc, 0.52, 0.42),
        (0.90, zc + 0.04, 0.56, 0.44),
        (2.70, zc + 0.16, 0.0, 0.0),
    ], sides=6, rot=0.0)
    common.body_mat(body)
    objects.append(body)

    nose = air.poly("nose_glass", [
        (0.0, -2.64, zc - 0.09),
        (0.0, -1.95, zc + 0.40),
        (0.46, -1.95, zc + 0.10),
        (-0.46, -1.95, zc + 0.10),
        (0.0, -1.95, zc - 0.26),
    ], [(0, 2, 1), (0, 1, 3), (0, 4, 2), (0, 3, 4)])
    air.glass_mat(nose)
    objects.append(nose)

    accents = []
    zw = zc + 0.10
    accents.append(air.bipyramid("wing", [
        (0.0, -0.85, zw),
        (2.65, 0.45, zw + 0.18),
        (2.65, 0.85, zw + 0.18),
        (0.0, 1.05, zw),
        (-2.65, 0.85, zw + 0.18),
        (-2.65, 0.45, zw + 0.18),
    ], top=(0.0, 0.20, zw + 0.18), bottom=(0.0, 0.20, zw - 0.16)))
    accents.append(air.bipyramid("tailplane", [
        (0.0, 1.85, zc + 0.20),
        (1.30, 2.35, zc + 0.24),
        (1.30, 2.62, zc + 0.24),
        (-1.30, 2.62, zc + 0.24),
        (-1.30, 2.35, zc + 0.24),
    ], top=(0.0, 2.35, zc + 0.30), bottom=(0.0, 2.35, zc + 0.14)))
    for side in (-1.0, 1.0):
        accents.append(air.tetra(
            f"fin_{side:+.0f}",
            (side * 1.15, 2.10, zc + 0.24),
            (side * 1.15, 2.65, zc + 0.24),
            (side * 1.20, 2.55, zc + 1.05),
            (side * 1.25, 2.40, zc + 0.26),
        ))
    for obj in accents:
        common.accent_mat(obj, accent)
        objects.append(obj)

    trims, glows = [], []
    for x in (-1.30, 1.30):
        z = zc + 0.02
        nacelle = air.loft(f"nacelle_{x:+.2f}", [
            (-0.55, z, 0.30, 0.28, x),
            (1.45, z, 0.22, 0.20, x),
        ], sides=4)
        common.body_mat(nacelle)
        objects.append(nacelle)
        r = 0.22 * 0.707 * 0.9
        glows.append(air.plate(f"exhaust_{x:+.2f}", (x, 1.465, z), (r, 0, 0), (0, 0, r * 0.9), (0, 1, 0)))

    trims.append(air.plate("bomb_bay", (0.0, 0.10, zc - 0.385), (0.24, 0, 0), (0, 1.1, 0), (0, 0, -1)))
    for obj in trims:
        common.trim_mat(obj)
        objects.append(obj)
    for obj in glows:
        common.glow_mat(obj, palette.JET_EXHAUST)
        objects.append(obj)

    return objects
