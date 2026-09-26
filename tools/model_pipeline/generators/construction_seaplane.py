"""unit_defs/seaplane.luau `construction_seaplane` (BAR corcsa): the flying builder off the Seaplane Platform.

Faceted low-poly, under 100 triangles. A little flying boat, nothing like the Construction Aircraft's stubby airframe:
a V-keeled boat hull whose tail sweeps up, a straight parasol wing held high over it on a pair of struts (the wing and
tail are the team-coloured accent), a float under each wing tip, and an engine pod on the wing's back driving a pusher
propeller that spins. On the nose sits a high-vis yellow nanolathe turret whose arm reaches forward to a glowing
emitter; it is the "work" piece and turns toward what the seaplane builds.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "construction_seaplane"


def generate(params):
    accent = params["color"]
    objects = []

    # Boat hull: a diamond section (keel, chine, deck ridge, chine), the tail swept up off the water.
    hull = air.loft("hull", [
        (-1.38, 0.62, 0.0, 0.0),
        (-0.85, 0.66, 0.42, 0.38),
        (0.35, 0.70, 0.36, 0.36),
        (1.38, 1.18, 0.0, 0.0),
    ], sides=4, rot=0.0)
    common.body_mat(hull)
    objects.append(hull)

    # Canopy: a dark wedge on the deck ridge behind the nanolathe.
    canopy = air.poly("canopy", [
        (0.0, -0.45, 1.02),
        (0.0, -0.02, 1.24),
        (0.22, 0.02, 1.00),
        (-0.22, 0.02, 1.00),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents, trims = [], []
    # Parasol wing, straight and high over the hull.
    zw = 1.78
    accents.append(air.bipyramid("wing", [
        (1.40, -0.30, zw), (1.40, 0.22, zw), (-1.40, 0.22, zw), (-1.40, -0.30, zw),
    ], top=(0.0, -0.08, zw + 0.12), bottom=(0.0, -0.08, zw - 0.10)))
    # Tail: an upright fin with a tailplane across it.
    accents.append(air.tetra(
        "fin",
        (0.0, 0.85, 1.00),
        (0.0, 1.40, 1.18),
        (0.0, 1.32, 1.75),
        (0.08, 1.10, 1.05),
    ))
    accents.append(air.bipyramid("tailplane", [
        (0.0, 1.05, 1.55), (0.62, 1.32, 1.56), (0.0, 1.42, 1.55), (-0.62, 1.32, 1.56),
    ], top=(0.0, 1.28, 1.60), bottom=(0.0, 1.28, 1.51)))

    for side in (-1.0, 1.0):
        # A strut up to the wing on each side, a thin wedge from the hull's shoulder.
        trims.append(air.tetra(
            f"strut_{side:+.0f}",
            (side * 0.18, -0.30, 0.95),
            (side * 0.18, 0.10, 0.95),
            (side * 0.72, -0.08, zw - 0.06),
            (side * 0.26, -0.10, 1.05),
        ))
        # A float under the wing tip, its keel drawn up into a blade that holds it to the wing.
        x = side * 1.22
        trims.append(air.tetra(
            f"float_{side:+.0f}",
            (x, -0.55, 0.55),
            (x - 0.13, 0.22, 0.66),
            (x + 0.13, 0.22, 0.66),
            (x, -0.02, zw - 0.04),
        ))

    # The engine pod on the wing's back, facing aft to its propeller.
    pod = air.loft("engine", [
        (-0.42, zw + 0.24, 0.0, 0.0),
        (-0.20, zw + 0.24, 0.17, 0.17),
        (0.40, zw + 0.24, 0.13, 0.13),
    ], sides=4)
    common.body_mat(pod)
    objects.append(pod)

    for obj in accents:
        common.accent_mat(obj, accent)
        objects.append(obj)
    for obj in trims:
        common.trim_mat(obj)
        objects.append(obj)

    # The pusher propeller: two crossed blades behind the pod, spinning about the pod's axis, each a face looking
    # either way so it shows from in front as well as behind.
    hub = (0.0, 0.44, zw + 0.24)
    blades = []
    for name, u, v in (("blade_a", (0.62, 0.0, 0.0), (0.0, 0.0, 0.07)),
                       ("blade_b", (0.0, 0.0, 0.46), (0.07, 0.0, 0.0))):
        for facing in (1.0, -1.0):
            blades.append(air.plate(f"{name}_{facing:+.0f}", (0.0, facing * 0.005, 0.0), u, v, (0.0, facing, 0.0)))
    prop = common.merge("propeller", blades, origin=hub)
    common.trim_mat(prop)
    objects.append(common.art_group(prop, "propeller", pivot=True, kind="spin", axis=(0.0, 1.0, 0.0), speed=30.0))

    # The nanolathe turret on the nose, built about its swivel point.
    pivot = (0.0, -0.72, 1.02)
    px, py, pz = pivot
    housing = air.poly("turret_housing", [
        (px - 0.20, py - 0.18, pz - 0.02), (px + 0.20, py - 0.18, pz - 0.02),
        (px + 0.20, py + 0.22, pz - 0.02), (px - 0.20, py + 0.22, pz - 0.02),
        (px, py + 0.04, pz + 0.26),
    ], [(0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)])
    arm = air.beam("arm", (px, py, pz + 0.12), (px, py - 0.40, pz + 0.22), 0.12, 0.10, top_scale=0.7,
                   open_start=True)
    tip = (px, py - 0.40, pz + 0.22)
    emitter = air.tetra(
        "emitter",
        (px, tip[1] - 0.14, tip[2]),
        (px - 0.08, tip[1] + 0.02, tip[2] - 0.06),
        (px + 0.08, tip[1] + 0.02, tip[2] - 0.06),
        (px, tip[1] + 0.02, tip[2] + 0.08),
    )
    for obj in (housing, arm):
        common.hivis_mat(obj)
        objects.append(common.art_group(obj, "nanolathe"))
    common.art_group(housing, "nanolathe", pivot=True, kind="work")
    common.nano_mat(emitter)
    objects.append(common.art_group(emitter, "nanolathe"))

    return objects
