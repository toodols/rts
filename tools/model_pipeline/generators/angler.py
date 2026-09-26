"""unit_defs/air_t2.luau `angler` (BAR cortitan): the torpedo bomber.

Faceted low-poly, under 100 triangles. Named for the anglerfish, and built like one so it reads apart from every other
plane: a short, fat hexagonal fuselage with a blunt glazed nose, and over the nose, arching forward on a thin mast, a
lure with a glowing tip (its sonar). A straight wing (the team-coloured accent, with the tail) carries two tail booms
running aft to a tailplane with a fin on each end, and the heavy torpedo it drops hangs under its belly. Nothing moves.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "angler"


def generate(params):
    accent = params["color"]
    zc = 2.40
    objects = []

    # The fat fuselage, a hexagon swelling fast behind a blunt nose and tapering to a tail cone between the booms.
    body = air.loft("fuselage", [
        (-2.00, zc - 0.10, 0.0, 0.0),
        (-1.35, zc, 0.72, 0.80),
        (0.95, zc + 0.10, 0.55, 0.60),
        (2.00, zc + 0.30, 0.0, 0.0),
    ], sides=6)
    common.body_mat(body)
    objects.append(body)

    canopy = air.poly("canopy", [
        (0.0, -1.95, zc + 0.02),
        (0.0, -1.25, zc + 0.90),
        (0.52, -1.25, zc + 0.32),
        (-0.52, -1.25, zc + 0.32),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    # The lure: a thin mast from the back of the head arching out over the nose, and its glowing tip.
    mast = air.tetra(
        "lure_mast",
        (-0.12, -0.85, zc + 0.72),
        (0.12, -0.85, zc + 0.72),
        (0.0, -2.30, zc + 1.55),
        (0.0, -1.10, zc + 1.02),
    )
    common.trim_mat(mast)
    objects.append(mast)
    tip = (0.0, -2.36, zc + 1.48)
    lure = air.tetra(
        "lure",
        (tip[0], tip[1] - 0.30, tip[2] - 0.14),
        (tip[0] - 0.26, tip[1] + 0.16, tip[2] - 0.18),
        (tip[0] + 0.26, tip[1] + 0.16, tip[2] - 0.18),
        (tip[0], tip[1], tip[2] + 0.28),
    )
    common.glow_mat(lure, palette.AQUA)
    objects.append(lure)

    accents, trims = [], []
    # A straight wing through the fuselage's shoulders.
    zw = zc + 0.25
    accents.append(air.bipyramid("wing", [
        (0.0, -0.60, zw),
        (2.80, -0.25, zw + 0.06),
        (2.80, 0.30, zw + 0.06),
        (0.0, 0.60, zw),
        (-2.80, 0.30, zw + 0.06),
        (-2.80, -0.25, zw + 0.06),
    ], top=(0.0, 0.0, zw + 0.20), bottom=(0.0, 0.0, zw - 0.18)))
    # Twin booms from the wing back to the tail, a tailplane between their ends and a fin standing on each.
    zt = zw + 0.05
    for side in (-1.0, 1.0):
        x = side * 1.25
        boom = air.beam(f"boom_{side:+.0f}", (x, -0.30, zt), (x, 2.60, zt), 0.26, 0.30, top_scale=0.8,
                        open_start=True)
        common.body_mat(boom)
        objects.append(boom)
        accents.append(air.tetra(
            f"fin_{side:+.0f}",
            (x, 1.85, zt + 0.12),
            (x, 2.75, zt + 0.12),
            (x, 2.65, zt + 1.05),
            (x + side * 0.10, 2.40, zt + 0.15),
        ))
    accents.append(air.bipyramid("tailplane", [
        (1.25, 2.05, zt + 0.10), (1.25, 2.70, zt + 0.10), (-1.25, 2.70, zt + 0.10), (-1.25, 2.05, zt + 0.10),
    ], top=(0.0, 2.40, zt + 0.20), bottom=(0.0, 2.40, zt + 0.02)))
    for obj in accents:
        common.accent_mat(obj, accent)
        objects.append(obj)

    # The heavy torpedo under the belly: a pointed nose and a square tail.
    torpedo = air.loft("torpedo", [
        (-1.45, zc - 0.90, 0.0, 0.0),
        (-0.95, zc - 0.90, 0.26, 0.26),
        (0.95, zc - 0.90, 0.24, 0.24),
    ], sides=4)
    trims.append(torpedo)
    for obj in trims:
        common.trim_mat(obj)
        objects.append(obj)

    return objects
