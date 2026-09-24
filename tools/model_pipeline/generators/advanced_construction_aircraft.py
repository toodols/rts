"""unit_defs/air_t2.luau `advanced_construction_aircraft`: the T2 flying builder.

Collider capsule(40, 20, 50): radius 50/22 = 2.27 studs, height 20/11 = 1.82. Faceted low-poly, under 100
triangles. The Construction Aircraft's bigger, heavier sibling, so the two read as family but never alike: a
longer, deeper squared fuselage, a swept wing with a big tilted lift fan pod on each tip (wing, pods and twin tail are
the team-coloured accent), and on its back a wide high-vis yellow nanolathe turret carrying two arms that reach
forward past the nose to a glowing emitter each. The turret is the "work" piece: it turns toward what it builds.
"""

from . import air_t1_common as air
from . import common

ACCENT = air.rgb(226, 178, 74)
RADIUS, HEIGHT = 50 / 22, 20 / 11


def generate(params):
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
        air.accent_mat(obj, "advanced_construction_aircraft", ACCENT)
        objects.append(obj)
    for obj in glows:
        air.glow_mat(obj)
        objects.append(obj)

    # The nanolathe turret, built about its swivel point on the fuselage's back, with two arms.
    pivot = (0.0, 0.30, zc + 0.34)
    px, py, pz = pivot
    housing = air.block("turret_housing", 0.80, 0.70, 0.30, 0.56, 0.46, top_offset=(0.0, 0.06),
                        origin=pivot, open_bottom=True)
    common.art_group(housing, "nanolathe", pivot=True, kind="work")
    air.hivis_mat(housing)
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
        air.hivis_mat(arm)
        objects.append(common.art_group(arm, "nanolathe"))
        tx, ty, tz = tip
        emitter = air.tetra(
            f"emitter_{side:+.0f}",
            (tx, ty - 0.16, tz - 0.04),
            (tx - 0.09, ty + 0.02, tz - 0.08),
            (tx + 0.09, ty + 0.02, tz - 0.08),
            (tx, ty + 0.02, tz + 0.09),
        )
        air.nano_mat(emitter)
        objects.append(common.art_group(emitter, "nanolathe"))

    air.flat(objects)
    air.check_fit(objects, RADIUS, HEIGHT, "advanced_construction_aircraft")
    return objects
