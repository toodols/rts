"""unit_defs/air_t2.luau `stiletto`: the EMP bomber.

Collider capsule(24, 9, 24): radius 24/22 = 1.09 studs, height 9/11 = 0.82. BAR's collision volume is far smaller than
its model, so this reaches past it, about as far as the Nighthawk. Faceted low-poly, under 100 triangles. A slim,
fast dart: a long narrow hexagonal fuselage with a glazed canopy, a swept delta wing and small canards ahead of it (the
team-coloured accent), two canted fins, twin exhausts, and under each wing an EMP pod glowing the pale turquoise of the
EMP it drops. Nothing moves: its bombs just drop.
"""

from . import air_t1_common as air
from . import common

ACCENT = air.rgb(96, 150, 190)
EMP = air.rgb(130, 215, 255)
RADIUS, HEIGHT = 24 / 22, 9 / 11


def generate(params):
    zc = 0.80
    objects = []

    body = air.loft("fuselage", [
        (-1.90, zc - 0.04, 0.0, 0.0),
        (-1.20, zc, 0.24, 0.20),
        (0.90, zc + 0.02, 0.28, 0.22),
        (1.70, zc + 0.06, 0.18, 0.14),
    ], sides=6, rot=0.0)
    common.body_mat(body)
    objects.append(body)

    canopy = air.poly("canopy", [
        (0.0, -1.35, zc + 0.12),
        (0.0, -0.55, zc + 0.36),
        (0.17, -0.70, zc + 0.18),
        (-0.17, -0.70, zc + 0.18),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents = []
    zw = zc - 0.04
    # A swept delta, its trailing edge notched either side of the tail.
    accents.append(air.bipyramid("wing", [
        (0.0, -0.70, zw),
        (1.55, 0.95, zw - 0.04),
        (1.40, 1.20, zw - 0.04),
        (0.35, 1.05, zw),
        (-0.35, 1.05, zw),
        (-1.40, 1.20, zw - 0.04),
        (-1.55, 0.95, zw - 0.04),
    ], top=(0.0, 0.40, zw + 0.12), bottom=(0.0, 0.40, zw - 0.10)))
    for side in (-1.0, 1.0):
        accents.append(air.tetra(
            f"canard_{side:+.0f}",
            (side * 0.18, -1.10, zc + 0.02),
            (side * 0.18, -0.80, zc + 0.02),
            (side * 0.62, -0.78, zc + 0.04),
            (side * 0.18, -0.95, zc + 0.08),
        ))
        accents.append(air.tetra(
            f"fin_{side:+.0f}",
            (side * 0.16, 1.00, zc + 0.16),
            (side * 0.16, 1.68, zc + 0.14),
            (side * 0.55, 1.62, zc + 0.68),
            (side * 0.12, 1.30, zc + 0.22),
        ))
    for obj in accents:
        air.accent_mat(obj, "stiletto", ACCENT)
        objects.append(obj)

    glows, pods = [], []
    for x in (-0.12, 0.12):
        r = 0.08
        glows.append(air.plate(f"exhaust_{x:+.2f}", (x, 1.705, zc + 0.06), (r, 0, 0), (0, 0, r), (0, 1, 0)))
    for x in (-0.85, 0.85):
        z = zw - 0.16
        pod = air.loft(f"emp_pod_{x:+.2f}", [
            (-0.05, z, 0.0, 0.0, x),
            (0.30, z, 0.11, 0.11, x),
            (0.85, z, 0.09, 0.09, x),
            (1.05, z, 0.0, 0.0, x),
        ], sides=4)
        pods.append(pod)
    for obj in glows:
        air.glow_mat(obj)
        objects.append(obj)
    for obj in pods:
        air.glow_mat(obj, EMP, "air_glow_emp")
        objects.append(obj)

    air.flat(objects)
    air.check_fit(objects, RADIUS, HEIGHT, "stiletto")
    return objects
