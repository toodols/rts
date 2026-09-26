"""unit_defs/seaplane.luau `dam_buster` (BAR corsb): the seaplane bomber.

Faceted low-poly, under 100 triangles. A big flying boat, not a jet like the Whirlwind: a deep V-keeled hull that steps
up to a raised tail, a long straight wing on its back (the team-coloured accent, with the tail), two engine nacelles
riding on top of the wing with glowing exhausts, a float under each wing tip, a twin-finned H tail and a dark bomb bay
along the belly. Nothing moves: its bombs just drop.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "dam_buster"


def generate(params):
    accent = params["color"]
    objects = []

    # Deep boat hull, diamond section, its tail stepping up off the water.
    hull = air.loft("hull", [
        (-2.00, 1.45, 0.0, 0.0),
        (-1.45, 1.52, 0.46, 0.66),
        (0.35, 1.58, 0.46, 0.64),
        (1.25, 2.10, 0.26, 0.40),
        (2.00, 2.62, 0.0, 0.0),
    ], sides=4, rot=0.0)
    common.body_mat(hull)
    objects.append(hull)

    canopy = air.poly("canopy", [
        (0.0, -1.75, 1.85),
        (0.0, -1.10, 2.30),
        (0.30, -1.05, 1.98),
        (-0.30, -1.05, 1.98),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents = []
    # A long straight wing on the hull's back, tapering to its tips.
    zw = 2.20
    accents.append(air.bipyramid("wing", [
        (0.0, -0.75, zw),
        (2.08, -0.35, zw - 0.04),
        (2.08, 0.10, zw - 0.04),
        (0.0, 0.40, zw),
        (-2.08, 0.10, zw - 0.04),
        (-2.08, -0.35, zw - 0.04),
    ], top=(0.0, -0.20, zw + 0.16), bottom=(0.0, -0.20, zw - 0.14)))
    # H tail: a tailplane across the raised tail, a fin standing on each end of it.
    zt = 2.55
    accents.append(air.bipyramid("tailplane", [
        (0.0, 1.40, zt), (1.05, 1.68, zt), (1.05, 1.98, zt), (-1.05, 1.98, zt), (-1.05, 1.68, zt),
    ], top=(0.0, 1.78, zt + 0.08), bottom=(0.0, 1.78, zt - 0.08)))
    for side in (-1.0, 1.0):
        x = side * 1.00
        accents.append(air.tetra(
            f"fin_{side:+.0f}",
            (x, 1.62, zt - 0.20),
            (x, 2.00, zt - 0.10),
            (x, 1.95, zt + 0.72),
            (x + side * 0.08, 1.85, zt),
        ))
    for obj in accents:
        common.accent_mat(obj, accent)
        objects.append(obj)

    trims, glows = [], []
    for side in (-1.0, 1.0):
        # An engine nacelle riding on top of the wing: a pointed intake, a glowing exhaust aft.
        x, z = side * 0.95, zw + 0.30
        nacelle = air.loft(f"nacelle_{side:+.0f}", [
            (-1.00, z, 0.0, 0.0, x),
            (-0.65, z, 0.24, 0.24, x),
            (0.55, z, 0.18, 0.18, x),
        ], sides=4)
        common.body_mat(nacelle)
        objects.append(nacelle)
        r = 0.18 * 0.707 * 0.9
        glows.append(air.plate(f"exhaust_{side:+.0f}", (x, 0.555, z), (r, 0, 0), (0, 0, r), (0, 1, 0)))
        # A float under the wing tip, hung on a keel blade.
        fx = side * 1.85
        trims.append(air.tetra(
            f"float_{side:+.0f}",
            (fx, -0.70, 1.00),
            (fx - 0.16, 0.20, 1.12),
            (fx + 0.16, 0.20, 1.12),
            (fx, -0.12, zw - 0.05),
        ))
    # Bomb bay doors along the belly, just aft of the step in the keel.
    trims.append(air.plate("bomb_bay", (0.0, -0.30, 0.95), (0.16, 0, 0), (0, 0.75, 0), (0, 0, -1)))
    for obj in trims:
        common.trim_mat(obj)
        objects.append(obj)
    for obj in glows:
        common.glow_mat(obj, palette.JET_EXHAUST)
        objects.append(obj)

    return objects
