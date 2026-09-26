"""unit_defs/seaplane.luau `cutlass` (BAR corcut): the seaplane gunship.

Faceted low-poly, under 100 triangles. A hovering boat: a V-keeled hull with a dark canopy, and on its back a great
curved blade of a fin, the cutlass it is named for (the team-coloured accent, with the stub wings). Each stub wing ends
in a lift nacelle glowing underneath, which is what holds it up, and a pair of dark cannon barrels juts from under its
chin. Nothing moves: its cannon fires whichever way its target is.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "cutlass"


def generate(params):
    accent = params["color"]
    objects = []

    # Boat hull, diamond section: keel below, chines to the sides, a ridge along the deck.
    hull = air.loft("hull", [
        (-2.05, 1.30, 0.0, 0.0),
        (-1.20, 1.36, 0.58, 0.62),
        (0.70, 1.46, 0.52, 0.56),
        (2.05, 2.05, 0.0, 0.0),
    ], sides=4, rot=0.0)
    common.body_mat(hull)
    objects.append(hull)

    canopy = air.poly("canopy", [
        (0.0, -1.70, 1.58),
        (0.0, -0.95, 2.10),
        (0.30, -0.90, 1.78),
        (-0.30, -0.90, 1.78),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents = []
    # The blade: a curved fin rising from the back and sweeping aft, thick along its spine, knife-edged all round.
    accents.append(air.bipyramid("blade", [
        (0.0, -0.55, 2.00),
        (0.0, 0.30, 2.95),
        (0.0, 1.20, 3.75),
        (0.0, 2.02, 4.05),
        (0.0, 1.55, 3.30),
        (0.0, 1.25, 2.30),
    ], top=(0.14, 0.75, 2.85), bottom=(-0.14, 0.75, 2.85)))
    # Stub wings, straight through the hull's shoulders.
    zw = 1.62
    accents.append(air.bipyramid("wings", [
        (1.45, -0.55, zw), (1.45, 0.25, zw), (-1.45, 0.25, zw), (-1.45, -0.55, zw),
    ], top=(0.0, -0.15, zw + 0.16), bottom=(0.0, -0.15, zw - 0.14)))
    for obj in accents:
        common.accent_mat(obj, accent)
        objects.append(obj)

    # A lift nacelle on each wing tip, and its glowing downwash underneath.
    glows = []
    for side in (-1.0, 1.0):
        x = side * 1.72
        nacelle = air.loft(f"nacelle_{side:+.0f}", [
            (-0.85, zw, 0.34, 0.40, x),
            (0.55, zw, 0.28, 0.32, x),
        ], sides=4)
        common.body_mat(nacelle)
        objects.append(nacelle)
        r = 0.20
        glows.append(air.plate(f"lift_{side:+.0f}", (x, -0.15, zw - 0.33), (r, 0, 0), (0, 0.5, 0), (0, 0, -1)))
    for obj in glows:
        common.glow_mat(obj, palette.JET_EXHAUST)
        objects.append(obj)

    # Twin cannon barrels under the chin, reaching out past the nose.
    for side in (-1.0, 1.0):
        barrel = air.beam(f"barrel_{side:+.0f}", (side * 0.22, -1.10, 1.08), (side * 0.22, -2.05, 1.08), 0.12, 0.12,
                          open_start=True)
        common.trim_mat(barrel)
        objects.append(barrel)

    return objects
