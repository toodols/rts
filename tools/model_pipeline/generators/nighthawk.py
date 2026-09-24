"""unit_defs/air_t2.luau `nighthawk`: the stealth fighter.

Collider capsule(36, 22, 44): radius 44/22 = 2.0 studs, height 22/11 = 2.0. Faceted low-poly, under 100 triangles.
All flat facets and sharp edges, like a stealth jet: a flat faceted pyramid of a body swept straight into a wide
arrowhead wing (the team-coloured accent, darkened), a faceted dark canopy, a V tail of two outward-canted fins, and a
thin exhaust slit glowing a cold blue rather than the other jets' amber. Nothing moves.
"""

from . import air_t1_common as air
from . import common

ACCENT = air.rgb(70, 74, 92)
EXHAUST = (0.35, 0.65, 1.0, 1.0)
RADIUS, HEIGHT = 44 / 22, 22 / 11


def generate(params):
    zc = 0.95
    objects = []

    # The body: a faceted ridge over a flat belly, from a sharp nose to a wide flat tail.
    body = air.poly("body", [
        (0.0, -1.95, zc - 0.02),     # 0 nose
        (0.0, -0.40, zc + 0.36),     # 1 ridge front
        (0.0, 1.30, zc + 0.26),      # 2 ridge back
        (0.46, -0.10, zc - 0.02),    # 3 right shoulder
        (-0.46, -0.10, zc - 0.02),   # 4 left shoulder
        (0.40, 1.55, zc - 0.02),     # 5 right tail
        (-0.40, 1.55, zc - 0.02),    # 6 left tail
        (0.0, 0.20, zc - 0.20),      # 7 belly
    ], [
        (0, 3, 1), (0, 1, 4),
        (1, 3, 5, 2), (1, 2, 6, 4),
        (2, 5, 6),
        (0, 7, 3), (0, 4, 7), (3, 7, 5), (4, 6, 7), (5, 7, 6),
    ])
    common.body_mat(body)
    objects.append(body)

    canopy = air.poly("canopy", [
        (0.0, -1.20, zc + 0.14),
        (0.0, -0.45, zc + 0.44),
        (0.22, -0.55, zc + 0.24),
        (-0.22, -0.55, zc + 0.24),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents = []
    zw = zc - 0.02
    # A wide arrowhead wing, faceted, its trailing edge notched.
    accents.append(air.bipyramid("wing", [
        (0.0, -1.10, zw),
        (1.65, 0.80, zw),
        (1.28, 1.05, zw),
        (0.55, 0.85, zw),
        (0.0, 1.20, zw),
        (-0.55, 0.85, zw),
        (-1.28, 1.05, zw),
        (-1.65, 0.80, zw),
    ], top=(0.0, 0.25, zw + 0.14), bottom=(0.0, 0.25, zw - 0.12)))
    for side in (-1.0, 1.0):
        accents.append(air.tetra(
            f"fin_{side:+.0f}",
            (side * 0.22, 0.75, zc + 0.20),
            (side * 0.30, 1.55, zc + 0.10),
            (side * 0.85, 1.45, zc + 0.78),
            (side * 0.16, 1.20, zc + 0.24),
        ))
    for obj in accents:
        air.accent_mat(obj, "nighthawk", ACCENT)
        objects.append(obj)

    slit = air.plate("exhaust", (0.0, 1.56, zc + 0.10), (0.30, 0, 0), (0, 0, 0.05), (0, 1, 0))
    air.glow_mat(slit, EXHAUST, "air_glow_stealth")
    objects.append(slit)

    air.flat(objects)
    air.check_fit(objects, RADIUS, HEIGHT, "nighthawk")
    return objects
