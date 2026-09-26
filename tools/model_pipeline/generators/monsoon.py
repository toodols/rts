"""unit_defs/seaplane.luau `monsoon` (BAR corseap): the torpedo gunship.

Faceted low-poly, under 100 triangles. A catamaran that flies: two long V-keeled float hulls, each with a small fin at
its stern, joined by a broad flat deck (the team-coloured accent, with the fins) that glows underneath where its lift
fans blow, a squat cockpit pod riding on the middle of the deck, and hung close beneath it between the hulls, the
torpedo it drops: a long dark casing with a pointed nose. Nothing moves.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "monsoon"


def generate(params):
    accent = params["color"]
    objects = []

    # The middle pod first, which the model is centred on: a squat hexagonal cabin on the deck.
    zd = 1.75
    pod = air.loft("pod", [
        (-1.55, zd + 0.10, 0.0, 0.0),
        (-0.70, zd + 0.22, 0.52, 0.42),
        (0.90, zd + 0.22, 0.46, 0.38),
        (1.45, zd + 0.18, 0.0, 0.0),
    ], sides=6, rot=0.0)
    common.body_mat(pod)
    objects.append(pod)

    canopy = air.poly("canopy", [
        (0.0, -1.30, zd + 0.28),
        (0.0, -0.55, zd + 0.78),
        (0.32, -0.50, zd + 0.48),
        (-0.32, -0.50, zd + 0.48),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents = []
    # The deck joining the hulls: a broad flat panel, knife-edged fore and aft.
    accents.append(air.bipyramid("deck", [
        (0.0, -1.10, zd),
        (1.62, -0.85, zd),
        (1.62, 0.95, zd),
        (0.0, 1.20, zd),
        (-1.62, 0.95, zd),
        (-1.62, -0.85, zd),
    ], top=(0.0, 0.05, zd + 0.14), bottom=(0.0, 0.05, zd - 0.14)))

    glows = []
    for side in (-1.0, 1.0):
        x = side * 1.55
        # A float hull under each edge of the deck.
        hull = air.loft(f"hull_{side:+.0f}", [
            (-2.05, 1.30, 0.0, 0.0, x),
            (-1.25, 1.34, 0.36, 0.52, x),
            (1.10, 1.40, 0.32, 0.48, x),
            (2.00, 1.62, 0.0, 0.0, x),
        ], sides=4, rot=0.0)
        common.body_mat(hull)
        objects.append(hull)
        # A small fin on its stern.
        accents.append(air.tetra(
            f"fin_{side:+.0f}",
            (x, 1.05, 1.80),
            (x, 1.95, 1.66),
            (x, 1.85, 2.55),
            (x + side * 0.08, 1.50, 1.85),
        ))
        # The lift fans' glow under the deck, inboard of the hull.
        glows.append(air.plate(f"lift_{side:+.0f}", (side * 0.82, 0.05, zd - 0.10), (0.30, 0, 0), (0, 0.55, 0),
                               (0, 0, -1)))
    for obj in accents:
        common.accent_mat(obj, accent)
        objects.append(obj)
    for obj in glows:
        common.glow_mat(obj, palette.AQUA)
        objects.append(obj)

    # The torpedo, slung under the deck between the hulls.
    torpedo = air.loft("torpedo", [
        (-1.35, 1.42, 0.0, 0.0),
        (-0.95, 1.42, 0.20, 0.20),
        (1.05, 1.42, 0.20, 0.20),
    ], sides=4)
    common.trim_mat(torpedo)
    objects.append(torpedo)

    return objects
