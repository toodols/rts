"""unit_defs `geothermal_powerplant` (corgeo): rust-orange accent. It caps a geothermal
vent. Budget: 100 triangles.

An armoured Cortex plant clamped over the vent, squat like corgeo (63 x 45 x 63 elmos): a dark chamfered deck, a
gunmetal sloped housing on it, and rising from the middle a waisted cooling-tower stack in the team colour, its mouth
glowing red-orange with the vent's heat. Two banks of three dark radiator fins brace the housing's flanks, and
glowing heat slits run along the housing's front and back. Nothing moves.
"""

import math

from .shared import common
from .shared import economy as eco
from .shared import palette

CATEGORY = "entity"
DEF = "geothermal_powerplant"


def generate(params):
    accent = params["color"]
    w = params["collider"]["width"]
    s = w / 8.0
    objects = []

    # deck: dark chamfered slab clamped over the ground (22 tris)
    deck_h = 0.9 * s
    deck = common.Faces().frustum(common.chamfered_rect(7.9 * s, 7.9 * s, 1.3 * s), common.chamfered_rect(7.0 * s, 7.0 * s, 1.0 * s), 0.0, deck_h)
    objects.append(common.trim_mat(deck.build("deck")))

    # housing: sloped armoured block (10 tris)
    house_top = deck_h + 1.7 * s
    house = common.Faces().frustum(common.rect(5.2 * s, 5.2 * s), common.rect(4.2 * s, 4.2 * s), deck_h, house_top)
    objects.append(common.body_mat(house.build("housing")))

    # stack: team-coloured hexagonal cooling tower, pinched at the waist and flaring to an open mouth (24 tris)
    waist_z = house_top + 2.1 * s
    stack_top = house_top + 3.3 * s
    stack = common.Faces()
    stack.frustum(common.ngon(6, 1.7 * s), common.ngon(6, 1.0 * s), house_top, waist_z, cap_top=False)
    stack.frustum(common.ngon(6, 1.0 * s), common.ngon(6, 1.3 * s), waist_z, stack_top, cap_top=False)
    objects.append(common.accent_mat(stack.build("stack"), accent))

    # the glowing mouth of the stack, and heat slits on the housing's front and back (4 + 4 tris)
    heat = common.Faces()
    heat.polygon(common.at(common.ngon(6, 1.3 * s), stack_top))
    for side in (-1.0, 1.0):
        # a slit laid on the sloped face at y = side * (face), hinged back to the slope
        ang = 0.0 if side > 0 else math.pi
        m = eco.matrix((0.0, 0.0, 0.0), (0.0, 0.0, ang))
        zc0, zc1 = deck_h + 0.45 * s, deck_h + 1.15 * s
        y0 = 2.6 * s - 0.5 * s * (zc0 - deck_h) / (1.7 * s) + 0.02 * s
        y1 = 2.6 * s - 0.5 * s * (zc1 - deck_h) / (1.7 * s) + 0.02 * s
        hx = 1.4 * s
        heat.polygon([(-hx, y0, zc0), (-hx, y1, zc1), (hx, y1, zc1), (hx, y0, zc0)], matrix=m)
    objects.append(common.glow_mat(heat.build("heat"), palette.VENT_HEAT))

    # radiator fins: three on each flank (6 tris each)
    fins = common.Faces()
    for ang in (0.0, math.pi):
        for off in (-1.5, 0.0, 1.5):
            m = eco.matrix((0.0, 0.0, 0.0), (0.0, 0.0, ang)) @ eco.matrix((0.0, off * s, 0.0))
            eco.wedge(fins, 0.0, 2.1 * s, 3.4 * s, 0.35 * s, deck_h, 1.6 * s, m=m)
    objects.append(common.trim_mat(fins.build("fins")))

    return objects
