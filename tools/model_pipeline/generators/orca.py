"""unit_defs/ship_t1.luau `orca` (BAR corsub): a submarine.

Collider capsule(35, 22, 50): radius 2.27, height 2 studs; it rides its `waterline` (about 4 studs) under the
surface, so everything is seen through the water from above. A long, flattened hexagonal hull, blunt at the bow and
tapering to the tail, a team-coloured sail with dive planes and a team stripe along the casing, cruciform tail fins,
and a propeller that spins. It has no turret: its torpedoes leave from the bow. Built to the 100-triangle limit
(ship_t1_common).
"""

import math

from . import common
from . import ship_t1_common as ship

NAME = "orca"
ACCENT = ship.rgb(120, 150, 196)
RADIUS, HEIGHT = 50 / 22, 22 / 11

ZC = 0.5  # the hull's axis
SQUASH = 0.78  # the hull is wider than it is tall


def _ring(y, r):
    return [(r * math.cos(math.radians(a)), y, ZC + r * SQUASH * math.sin(math.radians(a))) for a in range(0, 360, 60)]


def generate(params):
    # tail point, tail cone, full body, bow shoulder, blunt bow face (46 triangles)
    hull = ship.loft("hull", [
        [(0.0, 2.12, ZC)], _ring(1.75, 0.17), _ring(0.85, 0.5), _ring(-1.35, 0.5), _ring(-1.98, 0.3),
    ], cap_first=False, cap_last=True)
    objects = [ship.body(hull)]

    top = ZC + 0.5 * SQUASH * math.sin(math.radians(60))  # the hull's flat top
    half_top = 0.5 * math.cos(math.radians(60))
    # a team stripe down the flat top of the casing
    objects.append(ship.accent_mat(ship.deck_panel("casing", [
        (-half_top * 0.7, 0.85), (half_top * 0.7, 0.85), (half_top * 0.7, -1.35), (-half_top * 0.7, -1.35),
    ], top, lift=0.008), NAME, ACCENT))

    # Sail, forward of midships, with dive planes across it and a lit window at its front.
    sy = -0.45
    objects.append(ship.accent_mat(ship.block("sail", 0.3, 0.84, 0.5, 0.2, 0.6, off=(0.0, 0.1), origin=(0.0, sy, top - 0.02)), NAME, ACCENT))
    pz = top + 0.3
    objects.append(ship.trim(ship.fin("sail_planes", [(-0.42, sy - 0.12, pz), (0.42, sy - 0.12, pz), (0.42, sy + 0.08, pz), (-0.42, sy + 0.08, pz)])))
    objects.append(ship.glow_mat(ship.front_window("sail_light", 0.12, 0.06, sy - 0.42 + 0.064 - 0.006, top + 0.32, lean=0.018), NAME))

    # Cruciform tail: one fin standing up, planes across both sides.
    objects.append(ship.trim(ship.fin("tail_fin", [(0.0, 1.35, ZC + 0.3), (0.0, 1.95, ZC + 0.08), (0.0, 1.95, ZC + 0.62)])))
    objects.append(ship.trim(ship.fin("tail_planes", [(-0.62, 1.95, ZC), (-0.1, 1.35, ZC), (0.1, 1.35, ZC), (0.62, 1.95, ZC)])))

    # Three-bladed propeller on the tail cone, spinning about the hull's axis.
    py = 1.98
    blades = []
    for k in range(3):
        a = math.radians(90 + 120 * k)
        b = a + math.radians(38)
        blades.append((0.0, 0.0, 0.0))
        blades.append((0.32 * math.cos(a), 0.0, 0.32 * math.sin(a)))
        blades.append((0.32 * math.cos(b), 0.0, 0.32 * math.sin(b)))
    faces = [(3 * k, 3 * k + 1, 3 * k + 2) for k in range(3)]
    back = [(3 * k + 9, 3 * k + 11, 3 * k + 10) for k in range(3)]
    prop = ship.trim(ship.mesh("propeller", blades + blades, faces + back, origin=(0.0, py, ZC)))
    objects.append(common.art_group(prop, "propeller", pivot=True, kind="spin", axis=(0.0, 1.0, 0.0), speed=9.0))

    ship.report(NAME, objects, RADIUS, HEIGHT)
    return objects
