"""unit_defs/air_t1.luau `whirlwind` (BAR corshad): a bomber.

Collider capsule(44, 26, 48): radius 48/22 = 2.18 studs, height 26/11 = 2.36. Faceted low-poly, under 100
triangles. Heavier and broader than the Valiant so the two never read alike: a fat hexagonal fuselage with a
glazed nose, long swept wings (the team-coloured accent) carrying a big square engine nacelle each, a single
tall fin with a tailplane on top, and a dark bomb bay under the belly. Nothing moves: its bombs just drop.
"""

import math

from . import air_t1_common as air
from . import common

ACCENT = air.rgb(176, 122, 88)
RADIUS, HEIGHT = 48 / 22, 26 / 11


def generate(params):
    zc = 1.15
    objects = []

    body = air.loft("fuselage", [
        (-1.95, zc - 0.08, 0.0, 0.0),
        (-1.25, zc, 0.44, 0.34),
        (0.40, zc + 0.04, 0.48, 0.36),
        (1.95, zc + 0.14, 0.0, 0.0),
    ], sides=6, rot=0.0)
    common.body_mat(body)
    objects.append(body)

    # Glazed nose: a faceted cap over the fuselage's nose cone.
    nose = air.poly("nose_glass", [
        (0.0, -1.97, zc - 0.07),
        (0.0, -1.35, zc + 0.33),
        (0.40, -1.35, zc + 0.08),
        (-0.40, -1.35, zc + 0.08),
        (0.0, -1.35, zc - 0.22),
    ], [(0, 2, 1), (0, 1, 3), (0, 4, 2), (0, 3, 4)])
    air.glass_mat(nose)
    objects.append(nose)

    accents = []
    # Long swept wings, shoulder mounted, as one panel through the fuselage.
    zw = zc + 0.14
    accents.append(air.bipyramid("wing", [
        (0.0, -0.50, zw),
        (2.02, 0.33, zw + 0.16),
        (2.02, 0.72, zw + 0.16),
        (0.0, 0.90, zw),
        (-2.02, 0.72, zw + 0.16),
        (-2.02, 0.33, zw + 0.16),
    ], top=(0.0, 0.25, zw + 0.16), bottom=(0.0, 0.25, zw - 0.14)))
    # A tall fin, and a tailplane on top of it.
    accents.append(air.tetra(
        "fin",
        (0.0, 1.00, zc + 0.30),
        (0.0, 1.95, zc + 0.14),
        (0.0, 1.85, zc + 0.95),
        (0.0, 1.45, zc + 0.12),
    ))
    # the tetra's fourth point sits on the fin's own plane, so give the fin its thickness by nudging it
    fin = accents[-1]
    fin.data.vertices[3].co.x = 0.10
    accents.append(air.bipyramid("tailplane", [
        (0.0, 1.50, zc + 0.90),
        (0.80, 1.86, zc + 0.92),
        (0.0, 1.98, zc + 0.90),
        (-0.80, 1.86, zc + 0.92),
    ], top=(0.0, 1.80, zc + 0.96), bottom=(0.0, 1.80, zc + 0.86)))
    for obj in accents:
        air.accent_mat(obj, "whirlwind", ACCENT)
        objects.append(obj)

    # Engine nacelles under the wings: square-section tubes, dark intake faces, glowing nozzles.
    trims, glows = [], []
    for side in (-1.0, 1.0):
        x, z = side * 1.02, zc + 0.10
        nacelle = air.loft(f"nacelle_{side:+.0f}", [
            (-0.95, z, 0.22, 0.22, x),
            (1.10, z, 0.15, 0.15, x),
        ], sides=4)
        common.body_mat(nacelle)
        objects.append(nacelle)
        r = 0.22 * 0.707 * 0.85
        trims.append(air.plate(f"intake_{side:+.0f}", (x, -0.965, z), (r, 0, 0), (0, 0, r), (0, -1, 0)))
        r = 0.15 * 0.707 * 0.9
        glows.append(air.plate(f"exhaust_{side:+.0f}", (x, 1.115, z), (r, 0, 0), (0, 0, r), (0, 1, 0)))

    # Bomb bay doors: a dark plate along the belly.
    trims.append(air.plate("bomb_bay", (0.0, 0.0, zc - 0.305), (0.2, 0, 0), (0, 0.7, 0), (0, 0, -1)))
    for obj in trims:
        common.trim_mat(obj)
        objects.append(obj)
    for obj in glows:
        air.glow_mat(obj)
        objects.append(obj)

    air.flat(objects)
    air.check_fit(objects, RADIUS, HEIGHT, "whirlwind")
    return objects
