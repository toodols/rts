"""unit_defs/ship_t2.luau `messenger` (BAR cormship): the cruise missile ship.

A long, plain hull whose foredeck is one big
team-coloured launcher bed: the cruise missile's silo (weapon 1), fixed, with a pair of doors (its hatch) that swing
open when it fires. Behind it a tall superstructure, lit across its front, with a radar dish spinning on a mast, and on
the quarterdeck the anti-air missile turret (weapon 2), a small team-coloured box of launch cells. Built to the
100-triangle limit (shared/ship_t1.py).
"""

import math

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "messenger"
MOUNTS = {
    2: {"pivot": (0, 0.9297, -3.2136), "muzzle": (-0.3099, 0.508, 0.2858)},
}


def generate(params):
    accent = params["color"]
    hull = ship.Hull(8.0, 1.7, 0.6, [(0.0, 0.8), (0.3, 1.0), (0.7, 0.85), (1.0, 0.0)],
                     sheer=0.26, flare=0.8, rake=0.09)
    objects = [common.body_mat(hull.build())]
    objects.append(common.trim_mat(hull.build_deck()))

    # The launcher bed on the foredeck, and its doors, which open as the missile leaves.
    ly = -1.3
    lz = hull.deck_at(ly)
    objects.append(common.accent_mat(ship.block("launcher_bed", 1.1, 2.0, 0.3, 1.0, 1.9, origin=(0.0, ly, lz)), accent))
    # hinged along their after edge; right-hand rule about +X: negative lifts their front
    doors = common.trim_mat(ship.block("launcher_doors", 0.8, 1.6, 0.08, 0.76, 1.56, origin=(0.0, -0.8, 0.0)))
    doors = common.merge("launcher_doors", [doors], origin=(0.0, ly + 0.8, lz + 0.3))
    objects.append(common.art_group(doors, "launcher_doors", pivot=True, kind="hatch", weapon=1,
                                    axis=(1.0, 0.0, 0.0), open=-math.radians(70)))

    # A tall superstructure amidships, its windows forward, and the radar dish on its mast.
    cy = 0.8
    dz = hull.deck_at(cy)
    objects.append(common.body_mat(ship.block("superstructure", 1.1, 1.6, 0.8, 0.8, 1.2, off=(0.0, 0.15), origin=(0.0, cy, dz))))
    # its front face runs from y = cy - 0.8 at its foot to cy - 0.45 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.62, 0.12, cy - 0.8 + 0.28 - 0.01, dz + 0.62, lean=0.05), palette.AMBER))
    objects.append(common.trim_mat(ship.spire("mast", 0.14, 0.14, 0.9, origin=(0.0, cy + 0.2, dz + 0.78))))
    dish = common.trim_mat(ship.block("radar", 0.55, 0.1, 0.22, 0.45, 0.06, origin=(0.0, cy + 0.2, dz + 1.45)))
    objects.append(common.art_group(dish, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=2.6))

    # The anti-air missile turret on the quarterdeck: a box of launch cells, pitched up.
    ay = 2.8
    base = ship.block("aa_base", 0.46, 0.46, 0.16, 0.36, 0.36)
    cells = ship.loft("aa_cells", [
        [(-0.2, 0.22, -0.12), (0.2, 0.22, -0.12), (0.2, 0.22, 0.12), (-0.2, 0.22, 0.12)],
        [(-0.2, -0.22, -0.12), (0.2, -0.22, -0.12), (0.2, -0.22, 0.12), (-0.2, -0.22, 0.12)],
    ], cap_first=True, cap_last=True)
    cells.rotation_euler = (math.radians(-35.0), 0.0, 0.0)
    cells.location = (0.0, 0.0, 0.3)
    for p in (base, cells):
        common.accent_mat(p, accent)
    aa = common.merge("aa", [base, cells], origin=(0.0, ay, hull.deck_at(ay)))
    objects.append(common.art_group(aa, "turret_2", pivot=True, kind="turret", weapon=2))

    return objects
