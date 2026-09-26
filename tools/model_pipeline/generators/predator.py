"""unit_defs/ship_t2.luau `predator` (BAR corshark): the fast attack submarine.

A slim, pointed hull, a sharp nose tapering to a
long tail, with a low, swept, team-coloured sail set well aft like a shark's dorsal fin and a lit slit at its front,
swept dive planes forward, a cruciform tail and a propeller that spins. It has no turret: its torpedoes leave from the
bow. Built to the 100-triangle limit (shared/ship_t1.py).
"""

import math

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "predator"

ZC = 0.45  # the hull's axis
SQUASH = 0.8  # the hull is wider than it is tall


def _ring(y, r):
    return [(r * math.cos(math.radians(a)), y, ZC + r * SQUASH * math.sin(math.radians(a))) for a in range(0, 360, 60)]


def generate(params):
    # tail point, tail cone, full body, bow shoulder, nose point (48 triangles)
    accent = params["color"]
    hull = ship.loft("hull", [
        [(0.0, 2.2, ZC)], _ring(1.7, 0.16), _ring(0.5, 0.45), _ring(-0.9, 0.45), _ring(-1.7, 0.22), [(0.0, -2.15, ZC)],
    ], cap_first=False, cap_last=False)
    objects = [common.body_mat(hull)]

    top = ZC + 0.45 * SQUASH * math.sin(math.radians(60))  # the hull's flat top

    # A low, swept sail set aft, a shark's dorsal fin, with a lit slit at its front (12 triangles).
    sy = 0.15
    objects.append(common.accent_mat(ship.block(
        "sail", 0.24, 0.9, 0.42, 0.14, 0.4, off=(0.0, 0.3), origin=(0.0, sy, top - 0.02),
    ), accent))
    objects.append(common.glow_mat(ship.front_window("sail_light", 0.1, 0.05, sy - 0.45 + 0.08, top + 0.14, lean=0.05), palette.AMBER))

    # Swept dive planes forward, and a cruciform tail (6 triangles).
    fz = ZC + 0.05
    objects.append(common.trim_mat(ship.fin("bow_planes", [(-0.62, -0.7, fz), (-0.3, -1.05, fz), (0.3, -1.05, fz), (0.62, -0.7, fz)])))
    objects.append(common.trim_mat(ship.fin("tail_fin", [(0.0, 1.3, ZC + 0.3), (0.0, 2.05, ZC + 0.08), (0.0, 2.05, ZC + 0.62)])))
    objects.append(common.trim_mat(ship.fin("tail_planes", [(-0.6, 2.05, ZC), (-0.1, 1.35, ZC), (0.1, 1.35, ZC), (0.6, 2.05, ZC)])))

    # Three-bladed propeller on the tail, spinning about the hull's axis (6 triangles).
    py = 2.1
    blades = []
    for k in range(3):
        a = math.radians(90 + 120 * k)
        b = a + math.radians(38)
        blades.append((0.0, 0.0, 0.0))
        blades.append((0.3 * math.cos(a), 0.0, 0.3 * math.sin(a)))
        blades.append((0.3 * math.cos(b), 0.0, 0.3 * math.sin(b)))
    faces = [(3 * k, 3 * k + 1, 3 * k + 2) for k in range(3)]
    back = [(3 * k + 9, 3 * k + 11, 3 * k + 10) for k in range(3)]
    prop = common.trim_mat(ship.mesh("propeller", blades + blades, faces + back, origin=(0.0, py, ZC)))
    objects.append(common.art_group(prop, "propeller", pivot=True, kind="spin", axis=(0.0, 1.0, 0.0), speed=12.0))

    return objects
