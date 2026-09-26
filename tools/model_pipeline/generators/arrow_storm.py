"""unit_defs/ship_t2.luau `arrow_storm` (BAR corarch): the anti-air ship.

A trim, flush-decked hull with a raked bow, its deck
given over to its two anti-air mounts. Forward the missile racks (weapon 1): a pair of team-coloured launcher boxes
pitched steeply up on one swivel. Aft of a compact bridge block, lit across its front and with a mast behind, the flak
cannon (weapon 2): a small team-coloured gun house with two thin barrels raised high. Built to the 100-triangle limit
(shared/ship_t1.py).
"""

import math

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "arrow_storm"
MOUNTS = {
    1: {"pivot": (0, 0.8469, 1.6818), "muzzle": (-0.4087, 0.6574, 0.3251)},
    2: {"pivot": (0, 0.7568, -2.0182), "muzzle": (-0.227, 0.8783, 0.6507)},
}


def _box(name, w, h, length, x):
    """A closed launcher box along Y, centred on (x, 0, 0): 12 triangles."""
    rings = []
    for y in (length / 2, -length / 2):
        rings.append([(x - w / 2, y, -h / 2), (x + w / 2, y, -h / 2), (x + w / 2, y, h / 2), (x - w / 2, y, h / 2)])
    return ship.loft(name, rings, cap_first=True, cap_last=True)


def generate(params):
    accent = params["color"]
    hull = ship.Hull(6.0, 1.6, 0.5, [(0.0, 0.8), (0.3, 1.0), (0.75, 0.8), (1.0, 0.0)],
                     sheer=0.2, flare=0.8, rake=0.08)
    objects = [common.body_mat(hull.build())]
    objects.append(common.trim_mat(hull.build_deck()))

    # The missile racks forward: two launcher boxes on one swivel, pitched steeply up.
    ry = -1.5
    boxes = [_box(f"rack_{i}", 0.22, 0.22, 0.6, x) for i, x in enumerate((-0.16, 0.16))]
    for b in boxes:
        b.rotation_euler = (math.radians(-45.0), 0.0, 0.0)
        b.location = (0.0, 0.0, 0.3)
        common.accent_mat(b, accent)
    racks = common.merge("racks", boxes, origin=(0.0, ry, hull.deck_at(ry)))
    objects.append(common.art_group(racks, "turret_1", pivot=True, kind="turret", weapon=1))

    # A compact bridge block amidships, its windows forward and a mast behind.
    cy = 0.2
    dz = hull.deck_at(cy)
    objects.append(common.body_mat(ship.block("bridge", 0.9, 1.1, 0.55, 0.7, 0.8, off=(0.0, 0.1), origin=(0.0, cy, dz))))
    # the bridge's front face runs from y = cy - 0.55 at its foot to cy - 0.3 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.6, 0.1, cy - 0.55 + 0.2 - 0.01, dz + 0.42, lean=0.045), palette.AMBER))
    objects.append(common.trim_mat(ship.spire("mast", 0.14, 0.14, 1.1, origin=(0.0, cy + 0.2, dz + 0.53))))

    # The flak cannon aft: a small gun house with two thin barrels raised high.
    fy = 1.8
    house = ship.block("flak_house", 0.6, 0.6, 0.3, 0.45, 0.45)
    barrels = [ship.beam(f"flak_barrel_{i}", (x, 0.0, 0.2), (x, -0.55, 0.62), 0.1, 0.1, cap=False)
               for i, x in enumerate((-0.1, 0.1))]
    for p in [house] + barrels:
        common.accent_mat(p, accent)
    flak = common.merge("flak", [house] + barrels, origin=(0.0, fy, hull.deck_at(fy)))
    objects.append(common.art_group(flak, "turret_2", pivot=True, kind="turret", weapon=2))

    return objects
