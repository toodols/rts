"""unit_defs/air_t1.luau `construction_aircraft` (BAR corca): the flying builder.

Collider capsule(34, 18, 46): radius 46/22 = 2.09 studs, height 18/11 = 1.64 -- flat, so the whole thing is
low. Faceted low-poly, under 100 triangles. A stubby utility airframe, nothing like the combat planes: a short
deep hexagonal fuselage, a straight wing with a big square engine pod on each tip (wing, pods and V tail are
the team-coloured accent), and on its back a high-vis yellow nanolathe turret whose arm reaches forward over
the cockpit to a glowing emitter. The turret is the "work" piece: it turns toward what the aircraft builds.

Parts: body, trim (the canopy is dark trim glass, to stay within six parts), accent, engine glow, and the
turret's yellow and emitter glow.
"""

from . import air_t1_common as air
from . import common

ACCENT = air.rgb(226, 178, 74)
RADIUS, HEIGHT = 46 / 22, 18 / 11


def generate(params):
    zc = 0.72
    objects = []

    body = air.loft("fuselage", [
        (-1.55, zc - 0.10, 0.0, 0.0),
        (-0.95, zc, 0.40, 0.30),
        (0.55, zc + 0.02, 0.42, 0.30),
        (1.55, zc + 0.10, 0.0, 0.0),
    ], sides=6, rot=0.0)
    common.body_mat(body)
    objects.append(body)

    # Canopy: a raised wedge on top of the nose (open underneath, inside the body).
    canopy = air.poly("canopy", [
        (0.0, -1.30, zc + 0.04),
        (0.0, -0.78, zc + 0.40),
        (0.24, -0.72, zc + 0.24),
        (-0.24, -0.72, zc + 0.24),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    common.trim_mat(canopy)
    objects.append(canopy)

    accents = []
    # A straight wing through the fuselage, and a square engine pod on each tip.
    zw = zc + 0.05
    accents.append(air.bipyramid("wing", [
        (1.40, -0.30, zw), (1.40, 0.45, zw), (-1.40, 0.45, zw), (-1.40, -0.30, zw),
    ], top=(0.0, 0.05, zw + 0.14), bottom=(0.0, 0.05, zw - 0.12)))
    glows = []
    for side in (-1.0, 1.0):
        x, z = side * 1.55, zc + 0.06
        accents.append(air.loft(f"pod_{side:+.0f}", [
            (-0.80, z, 0.30, 0.30, x),
            (0.75, z, 0.24, 0.24, x),
        ], sides=4))
        r = 0.24 * 0.707 * 0.85
        glows.append(air.plate(f"exhaust_{side:+.0f}", (x, 0.765, z), (r, 0, 0), (0, 0, r), (0, 1, 0)))
        # V tail
        accents.append(air.tetra(
            f"tail_{side:+.0f}",
            (side * 0.10, 0.70, zc + 0.22),
            (side * 0.10, 1.45, zc + 0.14),
            (side * 0.66, 1.38, zc + 0.64),
            (side * 0.22, 1.10, zc + 0.14),
        ))
    for obj in accents:
        air.accent_mat(obj, "construction_aircraft", ACCENT)
        objects.append(obj)
    for obj in glows:
        air.glow_mat(obj)
        objects.append(obj)

    # The nanolathe turret, built about its swivel point on the fuselage's back.
    pivot = (0.0, 0.25, zc + 0.26)
    px, py, pz = pivot
    housing = air.block("turret_housing", 0.56, 0.62, 0.30, 0.36, 0.40, top_offset=(0.0, 0.06),
                        origin=pivot, open_bottom=True)
    arm = air.beam("arm", (px, py - 0.05, pz + 0.18), (px, py - 1.02, pz + 0.30), 0.17, 0.15,
                   top_scale=0.7, open_start=True)
    tip = (px, py - 1.02, pz + 0.30)
    emitter = air.tetra(
        "emitter",
        (px, tip[1] - 0.16, tip[2] - 0.04),
        (px - 0.10, tip[1] + 0.02, tip[2] - 0.08),
        (px + 0.10, tip[1] + 0.02, tip[2] - 0.08),
        (px, tip[1] + 0.02, tip[2] + 0.10),
    )
    for obj in (housing, arm):
        air.hivis_mat(obj)
        objects.append(common.art_group(obj, "nanolathe"))
    common.art_group(housing, "nanolathe", pivot=True, kind="work")
    air.nano_mat(emitter)
    objects.append(common.art_group(emitter, "nanolathe"))

    air.flat(objects)
    air.check_fit(objects, RADIUS, HEIGHT, "construction_aircraft")
    return objects
