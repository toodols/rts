"""unit_defs/air_t2.luau `advanced_construction_aircraft`: the T2 flying builder.

Faceted low-poly, under 100
triangles. The Construction Aircraft's bigger, heavier sibling, so the two read as family but never alike: a
longer, deeper squared fuselage, a swept wing with a big tilted lift fan pod on each tip (wing, pods and twin tail are
the team-coloured accent), and on its back a wide high-vis yellow nanolathe turret carrying two arms that reach
forward past the nose to a glowing emitter each. The turret is the "work" piece: it turns toward what it builds.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "advanced_construction_aircraft"
# an aircraft's BAR collision volume is only its fuselage's: the rest of it reaches past, as BAR's model does
ENVELOPE = {"width": 4.04, "length": 3.75}


def generate(params):
    accent = params["color"]
    zc = 0.80
    objects = []

    body = air.loft("fuselage", [
        (-1.90, zc - 0.08, 0.0, 0.0),
        (-1.20, zc, 0.46, 0.36),
        (0.70, zc + 0.02, 0.48, 0.36),
        (1.85, zc + 0.12, 0.10, 0.10),
    ], sides=4, rot=0.7854)
    common.body_mat(body)
    objects.append(body)

    canopy = air.poly("canopy", [
        (0.0, -1.62, zc + 0.08),
        (0.0, -1.00, zc + 0.46),
        (0.28, -0.92, zc + 0.28),
        (-0.28, -0.92, zc + 0.28),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents, glows = [], []
    zw = zc + 0.02
    accents.append(air.bipyramid("wing", [
        (0.0, -0.55, zw), (1.55, 0.05, zw + 0.06), (1.55, 0.60, zw + 0.06), (0.0, 0.70, zw),
        (-1.55, 0.60, zw + 0.06), (-1.55, 0.05, zw + 0.06),
    ], top=(0.0, 0.20, zw + 0.15), bottom=(0.0, 0.20, zw - 0.13)))
    for side in (-1.0, 1.0):
        x, z = side * 1.72, zc + 0.08
        # a lift fan pod: a squat eight-sided drum on the wing tip, its fan face glowing underneath
        accents.append(air.loft(f"pod_{side:+.0f}", [
            (-0.55, z, 0.42, 0.30, x),
            (0.60, z, 0.36, 0.26, x),
        ], sides=4))
        glows.append(air.plate(f"fan_{side:+.0f}", (x, 0.02, z - 0.23), (0.28, 0, 0), (0, 0.40, 0), (0, 0, -1)))
        accents.append(air.tetra(
            f"tail_{side:+.0f}",
            (side * 0.12, 0.95, zc + 0.26),
            (side * 0.12, 1.80, zc + 0.20),
            (side * 0.70, 1.70, zc + 0.78),
            (side * 0.26, 1.35, zc + 0.20),
        ))
    for obj in accents:
        common.accent_mat(obj, accent)
        objects.append(obj)
    for obj in glows:
        common.glow_mat(obj, palette.JET_EXHAUST)
        objects.append(obj)

    # The nanolathe turret, built about its swivel point on the fuselage's back, with two arms.
    pivot = (0.0, 0.30, zc + 0.34)
    px, py, pz = pivot
    housing = common.drop_bottom(common.block("turret_housing", 0.80, 0.70, 0.30, top=(0.56, 0.46), top_offset=(0.0, 0.06), origin=pivot))
    common.art_group(housing, "nanolathe", pivot=True, kind="work")
    common.hivis_mat(housing)
    objects.append(housing)
    for side in (-1.0, 1.0):
        root = (px + side * 0.26, py - 0.05, pz + 0.18)
        tip = (px + side * 0.30, py - 1.25, pz + 0.30)
        # an arm: a long three-sided spike from the housing out to the emitter
        arm = air.tetra(
            f"arm_{side:+.0f}",
            (tip[0], tip[1] + 0.05, tip[2]),
            (root[0] - 0.09, root[1], root[2] - 0.05),
            (root[0] + 0.09, root[1], root[2] - 0.05),
            (root[0], root[1], root[2] + 0.10),
        )
        common.hivis_mat(arm)
        objects.append(common.art_group(arm, "nanolathe"))
        tx, ty, tz = tip
        emitter = air.tetra(
            f"emitter_{side:+.0f}",
            (tx, ty - 0.16, tz - 0.04),
            (tx - 0.09, ty + 0.02, tz - 0.08),
            (tx + 0.09, ty + 0.02, tz - 0.08),
            (tx, ty + 0.02, tz + 0.09),
        )
        common.nano_mat(emitter)
        objects.append(common.art_group(emitter, "nanolathe"))

    return objects
