"""unit_defs/seaplane.luau `bat` (BAR corsfig): the seaplane fighter.

Faceted low-poly, under 100 triangles. Small and bat-like, so it reads apart from both the Valiant's dart and the
Liche's flying wing: a slim pod of a fuselage riding on a dark float keel, two broad wings that droop toward their tips
and whose trailing edges are scalloped between long finger points (the team-coloured accent, with the two pointed ears
on its head), a dark canopy, an anti-air missile under each wing and a glowing exhaust. Nothing moves.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "bat"


def generate(params):
    accent = params["color"]
    zc = 1.30
    objects = []

    body = air.loft("fuselage", [
        (-1.40, zc - 0.04, 0.0, 0.0),
        (-0.70, zc, 0.22, 0.24),
        (0.60, zc, 0.20, 0.20),
        (1.30, zc + 0.02, 0.0, 0.0),
    ], sides=4, rot=0.0)
    common.body_mat(body)
    objects.append(body)

    canopy = air.poly("canopy", [
        (0.0, -1.05, zc + 0.12),
        (0.0, -0.30, zc + 0.36),
        (0.14, -0.25, zc + 0.14),
        (-0.14, -0.25, zc + 0.14),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents, trims = [], []
    for side in (-1.0, 1.0):
        # A bat's wing: root along the fuselage, a leading edge drooping out to the tip, and a trailing edge that
        # scallops in between three finger points. Each is its own panel, thick at a ridge inboard.
        zr, zt = zc, zc - 0.32
        z = lambda x: zr + (zt - zr) * abs(x) / 1.42
        outline = [
            (side * 0.16, -0.55, zr),
            (side * 1.42, 0.00, zt),
            (side * 1.20, 0.80, z(1.20)),
            (side * 0.98, 0.40, z(0.98)),
            (side * 0.72, 0.95, z(0.72)),
            (side * 0.52, 0.52, z(0.52)),
            (side * 0.16, 0.85, zr),
        ]
        ridge = (side * 0.55, 0.10, z(0.55))
        accents.append(air.bipyramid(f"wing_{side:+.0f}", outline, top=(ridge[0], ridge[1], ridge[2] + 0.07),
                                     bottom=(ridge[0], ridge[1], ridge[2] - 0.06)))
        # A pointed ear on the head, canted out.
        accents.append(air.tetra(
            f"ear_{side:+.0f}",
            (side * 0.08, -0.55, zc + 0.16),
            (side * 0.10, -0.20, zc + 0.14),
            (side * 0.30, -0.28, zc + 0.62),
            (side * 0.16, -0.35, zc + 0.10),
        ))
        # An anti-air missile under the wing.
        x, zm = side * 0.70, z(0.70) - 0.10
        trims.append(air.tetra(
            f"missile_{side:+.0f}",
            (x, -0.45, zm),
            (x - 0.05, 0.40, zm + 0.02),
            (x + 0.05, 0.40, zm + 0.02),
            (x, 0.40, zm - 0.07),
        ))
    # The float keel under the fuselage, what it sits on the water on.
    trims.append(air.poly("keel", [
        (0.0, -1.05, zc - 0.20),
        (0.0, 0.70, zc - 0.18),
        (0.0, -0.20, zc - 0.62),
        (0.12, -0.10, zc - 0.18),
        (-0.12, -0.10, zc - 0.18),
    ], [(0, 2, 3), (3, 2, 1), (0, 4, 2), (4, 1, 2)]))
    for obj in accents:
        common.accent_mat(obj, accent)
        objects.append(obj)
    for obj in trims:
        common.trim_mat(obj)
        objects.append(obj)

    y = 1.305
    glow = air.poly("exhaust", [
        (0.10, y, zc), (0.0, y, zc + 0.08), (-0.10, y, zc), (0.0, y, zc - 0.08),
    ], [(0, 1, 2, 3)], facing=(0.0, 1.0, 0.0))
    common.glow_mat(glow, palette.JET_EXHAUST)
    objects.append(glow)

    return objects
