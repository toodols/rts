"""unit_defs/ship_t2.luau `kraken` (BAR corssub): the long-range battle submarine.

BAR's is almost as wide as it is long, so this
is a broad, flat, manta-like hull, a wide flattened hexagon blunt at both ends, with a raised team-coloured back
running down its middle, a squat, wide sail forward on it lit across its front, a twin tail of fins aft, and a pair of
propellers that spin. It has no turret: its heavy torpedo leaves from the bow. Built to the 100-triangle limit
(shared/ship_t1.py).
"""

import math

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "kraken"

ZC = 0.45  # the hull's axis
SQUASH = 0.42  # the hull is much wider than it is tall


def _ring(y, r):
    return [(r * math.cos(math.radians(a)), y, ZC + r * SQUASH * math.sin(math.radians(a))) for a in range(0, 360, 60)]


def _propeller(name, x, y):
    """A three-bladed propeller at (x, y) on the hull's axis, spinning about it: 6 triangles."""
    blades = []
    for k in range(3):
        a = math.radians(90 + 120 * k)
        b = a + math.radians(38)
        blades.append((0.0, 0.0, 0.0))
        blades.append((0.22 * math.cos(a), 0.0, 0.22 * math.sin(a)))
        blades.append((0.22 * math.cos(b), 0.0, 0.22 * math.sin(b)))
    faces = [(3 * k, 3 * k + 1, 3 * k + 2) for k in range(3)]
    back = [(3 * k + 9, 3 * k + 11, 3 * k + 10) for k in range(3)]
    prop = common.trim_mat(ship.mesh(name, blades + blades, faces + back, origin=(x, y, ZC)))
    return common.art_group(prop, name, pivot=True, kind="spin", axis=(0.0, 1.0, 0.0), speed=7.0)


def generate(params):
    # stern face, full body, bow shoulder, blunt bow face (38 triangles)
    accent = params["color"]
    hull = ship.loft("hull", [
        _ring(1.3, 0.75), _ring(0.8, 1.05), _ring(-0.7, 1.05), _ring(-1.3, 0.7),
    ], cap_first=True, cap_last=True)
    objects = [common.body_mat(hull)]

    top = ZC + 1.05 * SQUASH * math.sin(math.radians(60))  # the hull's flat top

    # A raised team-coloured back down its middle (10 triangles), and a squat, wide sail forward on it (10).
    objects.append(common.accent_mat(ship.block(
        "back", 0.9, 2.2, 0.14, 0.7, 2.0, origin=(0.0, 0.1, top - 0.02),
    ), accent))
    sy = -0.5
    objects.append(common.accent_mat(ship.block(
        "sail", 0.6, 0.6, 0.36, 0.44, 0.42, off=(0.0, 0.06), origin=(0.0, sy, top + 0.1),
    ), accent))
    objects.append(common.glow_mat(ship.front_window("sail_light", 0.3, 0.06, sy - 0.3 + 0.07, top + 0.3, lean=0.035), palette.AMBER))

    # A twin tail: a fin standing up on either side of the stern, with planes out across it (8 triangles).
    for side in (-1.0, 1.0):
        x = side * 0.45
        objects.append(common.trim_mat(ship.fin(f"tail_fin_{side:+.0f}", [
            (x, 0.9, top - 0.02), (x, 1.5, top - 0.02), (x, 1.55, top + 0.38),
        ])))
    objects.append(common.trim_mat(ship.fin("tail_planes", [(-1.1, 1.45, ZC), (-0.6, 1.0, ZC), (0.6, 1.0, ZC), (1.1, 1.45, ZC)])))

    # Twin propellers on the stern (12 triangles).
    objects.append(_propeller("propeller_l", -0.4, 1.35))
    objects.append(_propeller("propeller_r", 0.4, 1.35))

    return objects
