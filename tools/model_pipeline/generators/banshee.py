"""unit_defs/air_t1.luau `banshee` (BAR armkam): the light gunship.

Faceted low-poly, under 100 triangles. A compact hovering gunship: a stubby hexagonal body with a dark canopy, a pair
of forward-swept wings (the team-coloured accent, with its single fin) each ending in a squat lift pod that blows
straight down, glowing underneath, and a dark gun barrel under its chin. Nothing moves: its gun fires whichever way its
target is.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "banshee"


def generate(params):
    accent = params["color"]
    zc = 1.35
    objects = []

    body = air.loft("fuselage", [
        (-1.30, zc - 0.10, 0.0, 0.0),
        (-0.70, zc, 0.36, 0.34),
        (0.80, zc + 0.04, 0.28, 0.26),
    ], sides=6)
    common.body_mat(body)
    objects.append(body)

    canopy = air.poly("canopy", [
        (0.0, -1.05, zc + 0.10),
        (0.0, -0.45, zc + 0.46),
        (0.22, -0.40, zc + 0.24),
        (-0.22, -0.40, zc + 0.24),
    ], [(0, 2, 1), (0, 1, 3), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents = []
    # Forward-swept wings: the tips reach ahead of the roots.
    zw = zc + 0.02
    accents.append(air.bipyramid("wings", [
        (0.0, -0.10, zw),
        (1.05, -0.55, zw + 0.06),
        (1.05, -0.20, zw + 0.06),
        (0.0, 0.55, zw),
        (-1.05, -0.20, zw + 0.06),
        (-1.05, -0.55, zw + 0.06),
    ], top=(0.0, 0.10, zw + 0.14), bottom=(0.0, 0.10, zw - 0.12)))
    accents.append(air.tetra(
        "fin",
        (0.0, 0.35, zc + 0.22),
        (0.0, 0.95, zc + 0.16),
        (0.0, 0.92, zc + 0.80),
        (0.07, 0.62, zc + 0.24),
    ))
    for obj in accents:
        common.accent_mat(obj, accent)
        objects.append(obj)

    # A squat lift pod standing on each wing tip, glowing where it blows down.
    glows = []
    for side in (-1.0, 1.0):
        x, y = side * 1.18, -0.38
        pod = air.beam(f"pod_{side:+.0f}", (x, y, zw - 0.34), (x, y, zw + 0.30), 0.34, 0.44, top_scale=0.8)
        common.body_mat(pod)
        objects.append(pod)
        glows.append(air.plate(f"lift_{side:+.0f}", (x, y, zw - 0.35), (0.13, 0, 0), (0, 0.18, 0), (0, 0, -1)))
    for obj in glows:
        common.glow_mat(obj, palette.JET_EXHAUST)
        objects.append(obj)

    barrel = air.beam("barrel", (0.0, -0.80, zc - 0.28), (0.0, -1.40, zc - 0.28), 0.10, 0.10, open_start=True)
    common.trim_mat(barrel)
    objects.append(barrel)

    return objects
