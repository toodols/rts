"""unit_defs `geothermal_powerplant` (corgeo): 2x2x2 cells (8x8x8 studs), rust-orange accent. It caps a geothermal
vent. Budget: 100 triangles.

An armoured Cortex plant clamped over the vent, squat like corgeo (63 x 45 x 63 elmos): a dark chamfered deck, a
gunmetal sloped housing on it, and rising from the middle a waisted cooling-tower stack in the team colour, its mouth
glowing red-orange with the vent's heat. Two banks of three dark radiator fins brace the housing's flanks, and
glowing heat slits run along the housing's front and back. Nothing moves.
"""

import math

from . import economy_common as eco

ACCENT = (0.839, 0.431, 0.243, 1.0)  # unit_defs Color3.fromRGB(214, 110, 62)
HEAT_GLOW = (1.0, 0.24, 0.05, 1.0)  # the vent's heat, redder than an extractor's molten ore


def generate(params):
    w = float(params.get("width", 8.0))
    s = w / 8.0
    objects = []

    # deck: dark chamfered slab clamped over the ground (22 tris)
    deck_h = 0.9 * s
    deck = eco.Mesh().frustum(eco.chamfered_rect(7.9 * s, 7.9 * s, 1.3 * s), eco.chamfered_rect(7.0 * s, 7.0 * s, 1.0 * s), 0.0, deck_h)
    objects.append(eco.trim(deck.build("deck")))

    # housing: sloped armoured block (10 tris)
    house_top = deck_h + 1.7 * s
    house = eco.Mesh().frustum(eco.rect(5.2 * s, 5.2 * s), eco.rect(4.2 * s, 4.2 * s), deck_h, house_top)
    objects.append(eco.body(house.build("housing")))

    # stack: team-coloured hexagonal cooling tower, pinched at the waist and flaring to an open mouth (24 tris)
    waist_z = house_top + 2.1 * s
    stack_top = house_top + 3.3 * s
    stack = eco.Mesh()
    stack.frustum(eco.ngon(1.7 * s, 6), eco.ngon(1.0 * s, 6), house_top, waist_z, cap_top=False)
    stack.frustum(eco.ngon(1.0 * s, 6), eco.ngon(1.3 * s, 6), waist_z, stack_top, cap_top=False)
    objects.append(eco.accent(stack.build("stack"), "geo", ACCENT))

    # the glowing mouth of the stack, and heat slits on the housing's front and back (4 + 4 tris)
    heat = eco.Mesh()
    heat.poly(eco.at(eco.ngon(1.3 * s, 6), stack_top))
    for side in (-1.0, 1.0):
        # a slit laid on the sloped face at y = side * (face), hinged back to the slope
        ang = 0.0 if side > 0 else math.pi
        m = eco.matrix((0.0, 0.0, 0.0), (0.0, 0.0, ang))
        zc0, zc1 = deck_h + 0.45 * s, deck_h + 1.15 * s
        y0 = 2.6 * s - 0.5 * s * (zc0 - deck_h) / (1.7 * s) + 0.02 * s
        y1 = 2.6 * s - 0.5 * s * (zc1 - deck_h) / (1.7 * s) + 0.02 * s
        hx = 1.4 * s
        heat.poly([(-hx, y0, zc0), (-hx, y1, zc1), (hx, y1, zc1), (hx, y0, zc0)], m=m)
    objects.append(eco.glow(heat.build("heat"), "geo", HEAT_GLOW, emission=1.2))

    # radiator fins: three on each flank (6 tris each)
    fins = eco.Mesh()
    for ang in (0.0, math.pi):
        for off in (-1.5, 0.0, 1.5):
            m = eco.matrix((0.0, 0.0, 0.0), (0.0, 0.0, ang)) @ eco.matrix((0.0, off * s, 0.0))
            eco.wedge(fins, 0.0, 2.1 * s, 3.4 * s, 0.35 * s, deck_h, 1.6 * s, m=m)
    objects.append(eco.trim(fins.build("fins")))

    return objects
