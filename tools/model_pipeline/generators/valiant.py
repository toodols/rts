"""unit_defs/air_t1.luau `valiant` (BAR corveng): a light anti-air fighter.

Built as a
faceted low-poly dart, about fifty triangles: a diamond-section fuselage with sharp chines, a cockpit canopy
facet, one cropped-delta wing panel (the team-coloured accent) that is thick at the root and knife-edged at the
rim, twin outward-canted fins, a homing missile under each wing and a glowing exhaust face. Nothing moves: the
fighter's weapon has no turret, it just points the plane.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "valiant"


def generate(params):
    accent = params["color"]
    zc = 1.25  # fuselage centreline, about the middle of the collider
    objects = []

    # Diamond-section fuselage (points right, top, left, bottom): nose, shoulders over the wing root, tail.
    body = air.loft("fuselage", [
        (-1.72, zc - 0.03, 0.0, 0.0),
        (-0.40, zc, 0.27, 0.20),
        (1.72, zc, 0.21, 0.14),
    ], sides=4, square=2.0, rot=0.0)
    common.body_mat(body)
    objects.append(body)

    # Canopy: four facets raised off the fuselage's top ridge (its open underside is inside the body).
    front, back = (0.0, -1.12, zc + 0.07), (0.0, 0.05, zc + 0.20)
    top = (0.0, -0.58, zc + 0.30)
    left, right = (-0.13, -0.58, zc + 0.08), (0.13, -0.58, zc + 0.08)
    canopy = air.poly("canopy", [front, back, top, left, right], [(0, 4, 2), (0, 2, 3), (1, 2, 4), (1, 3, 2)])
    air.glass_mat(canopy)
    objects.append(canopy)

    # One cropped-delta wing panel through the fuselage, thick at the root and knife-edged at the rim.
    zw = zc - 0.03
    wing = air.bipyramid("wing", [
        (0.0, -0.55, zw),
        (1.30, 0.62, zw - 0.08),
        (1.30, 1.02, zw - 0.08),
        (0.0, 1.15, zw),
        (-1.30, 1.02, zw - 0.08),
        (-1.30, 0.62, zw - 0.08),
    ], top=(0.0, 0.45, zw + 0.13), bottom=(0.0, 0.45, zw - 0.16))
    common.accent_mat(wing, accent)
    objects.append(wing)

    # Twin fins canted outward, each a tetrahedron: root leading edge, root trailing edge, tip, and a point
    # set inboard to give it thickness.
    for side in (-1.0, 1.0):
        fin = air.tetra(
            f"fin_{side:+.0f}",
            (side * 0.13, 0.90, zc + 0.12),
            (side * 0.13, 1.70, zc + 0.09),
            (side * 0.44, 1.58, zc + 0.72),
            (side * 0.08, 1.30, zc + 0.22),
        )
        common.accent_mat(fin, accent)
        objects.append(fin)

    # A homing missile slung under each wing: a long dark spike.
    for side in (-1.0, 1.0):
        x, z = side * 0.78, zc - 0.14
        missile = air.tetra(
            f"missile_{side:+.0f}",
            (x, -0.30, z),
            (x - 0.06, 0.72, z + 0.02),
            (x + 0.06, 0.72, z + 0.02),
            (x, 0.72, z - 0.08),
        )
        common.trim_mat(missile)
        objects.append(missile)

    # Exhaust: a glowing diamond just behind the tail face.
    y = 1.735
    glow = air.poly("exhaust", [
        (0.17, y, zc), (0.0, y, zc + 0.11), (-0.17, y, zc), (0.0, y, zc - 0.11),
    ], [(0, 1, 2, 3)], facing=(0.0, 1.0, 0.0))
    common.glow_mat(glow, palette.JET_EXHAUST)
    objects.append(glow)

    return objects
