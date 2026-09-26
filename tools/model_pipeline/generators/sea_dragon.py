"""unit_defs/ship_t1.luau `sea_dragon` (BAR armseadragon): a nuclear missile submarine.

A long, flattened hexagonal hull, twice the Orca's
length, with a raised missile deck behind the sail carrying two rows of team-coloured launch hatches, which is what
tells it apart from a hunter submarine at a glance. A team-coloured sail with dive planes sits forward, cruciform tail
fins aft, and a propeller that spins. It has no turret: its torpedoes leave from the bow and its missiles from the
hatches. Built to the 100-triangle limit (shared/ship_t1.py).
"""

import math

from .shared import common
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "sea_dragon"
ZC = 0.75  # the hull's axis
SQUASH = 0.7  # the hull is wider than it is tall
BODY_R = 0.85


def _ring(y, r):
    return [(r * math.cos(math.radians(a)), y, ZC + r * SQUASH * math.sin(math.radians(a))) for a in range(0, 360, 60)]


def generate(params):
    # tail point, tail cone, full body, bow shoulder, blunt bow face (46 triangles)
    accent = params["color"]
    hull = ship.loft("hull", [
        [(0.0, 4.95, ZC)], _ring(4.2, 0.28), _ring(2.8, BODY_R), _ring(-3.4, BODY_R), _ring(-4.5, 0.5),
    ], cap_first=False, cap_last=True)
    objects = [common.body_mat(hull)]

    top = ZC + BODY_R * SQUASH * math.sin(math.radians(60))  # the hull's flat top

    # The missile deck: a long low hump down the casing behind the sail (10 triangles).
    deck_h = 0.28
    deck_y0, deck_y1 = -0.75, 2.55
    objects.append(common.trim_mat(ship.block(
        "missile_deck", 0.8, deck_y1 - deck_y0, deck_h, tw=0.7, tl=deck_y1 - deck_y0 - 0.1,
        origin=(0.0, (deck_y0 + deck_y1) / 2, top - 0.02),
    )))
    # Two rows of four launch hatches on it, in the team's colour (16 triangles).
    hatch_z = top - 0.02 + deck_h
    hatches = []
    for row in range(4):
        y = -0.3 + row * 0.75
        for x in (-0.17, 0.17):
            hatches.append(ship.deck_panel(f"hatch_{row}_{'l' if x < 0 else 'r'}", [
                (x - 0.13, y - 0.25), (x + 0.13, y - 0.25), (x + 0.13, y + 0.25), (x - 0.13, y + 0.25),
            ], hatch_z, lift=0.008))
    objects.append(common.accent_mat(common.merge("hatches", hatches), accent))

    # Sail, forward of the missile deck, with dive planes across it (14 triangles).
    sy = -1.6
    objects.append(common.accent_mat(ship.block(
        "sail", 0.4, 1.2, 0.75, 0.28, 0.85, off=(0.0, 0.15), origin=(0.0, sy, top - 0.02),
    ), accent))
    pz = top + 0.45
    objects.append(common.trim_mat(ship.fin("sail_planes", [
        (-0.65, sy - 0.25, pz), (0.65, sy - 0.25, pz), (0.65, sy + 0.05, pz), (-0.65, sy + 0.05, pz),
    ])))

    # Cruciform tail: one fin standing up, planes across both sides (6 triangles).
    objects.append(common.trim_mat(ship.fin("tail_fin", [(0.0, 3.3, ZC + 0.55), (0.0, 4.55, ZC + 0.12), (0.0, 4.55, ZC + 1.05)])))
    objects.append(common.trim_mat(ship.fin("tail_planes", [(-1.0, 4.55, ZC), (-0.2, 3.4, ZC), (0.2, 3.4, ZC), (1.0, 4.55, ZC)])))

    # Three-bladed propeller on the tail cone, spinning about the hull's axis (6 triangles).
    py = 4.6
    blades = []
    for k in range(3):
        a = math.radians(90 + 120 * k)
        b = a + math.radians(38)
        blades.append((0.0, 0.0, 0.0))
        blades.append((0.5 * math.cos(a), 0.0, 0.5 * math.sin(a)))
        blades.append((0.5 * math.cos(b), 0.0, 0.5 * math.sin(b)))
    faces = [(3 * k, 3 * k + 1, 3 * k + 2) for k in range(3)]
    back = [(3 * k + 9, 3 * k + 11, 3 * k + 10) for k in range(3)]
    prop = common.trim_mat(ship.mesh("propeller", blades + blades, faces + back, origin=(0.0, py, ZC)))
    objects.append(common.art_group(prop, "propeller", pivot=True, kind="spin", axis=(0.0, 1.0, 0.0), speed=7.0))

    return objects
