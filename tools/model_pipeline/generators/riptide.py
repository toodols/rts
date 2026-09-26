"""unit_defs/ship_t1.luau `riptide` (BAR corpship): a gun ship with one light plasma cannon.

A monitor: a broad, low hull that is little more than
a mount for its one gun. The twin plasma cannon's team-coloured gun house is nearly as wide as the deck and fills
the fore half of the ship, with two long, heavy barrels over the bow; everything else is pushed right aft into one
small, tall tower with the team-coloured bridge on top, a mast and a spinning radar bar. From above it is one big
block of team colour forward. Built to the 100-triangle limit (shared/ship_t1.py).
"""

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "riptide"
MOUNTS = {
    1: {"pivot": (0, 0.4987, 0.989), "muzzle": (-0.3889, 0.1194, 1.8739)},
}


def _cannon(swivel, accent):
    """The twin plasma cannon: a huge, flat, sloped gun house (accent) and two long barrels (trim). 24 triangles."""
    house = common.accent_mat(ship.block("turret_house", 1.36, 1.6, 0.36, 1.04, 1.1, off=(0.0, 0.2)), accent)
    head = common.merge("turret", [house], origin=swivel)
    guns = []
    for side in (-1.0, 1.0):
        guns.append(common.trim_mat(ship.bar("gun", 0.17, 0.16, 1.3, -0.5, 0.18, x=side * 0.24, taper=0.8)))
    return head, common.merge("turret_guns", guns, origin=swivel)


def generate(params):
    accent = params["color"]
    hull = ship.Hull(6.2, 1.8, 0.46, [(0.0, 0.84), (0.2, 1.0), (0.6, 1.0), (0.84, 0.72), (1.0, 0.0)],
                     sheer=0.18, flare=0.82, rake=0.1)
    objects = [common.body_mat(hull.build())]
    objects.append(common.trim_mat(hull.build_deck()))

    ty = -0.95
    head, guns = _cannon((0.0, ty, hull.deck_at(ty)), accent)
    objects.append(common.art_group(head, "turret_1", pivot=True, kind="turret", weapon=1))
    objects.append(common.art_group(guns, "turret_1"))

    # The tower right aft: a tall, narrow block with the bridge on top.
    cy = 2.05
    dz = hull.deck_at(cy)
    objects.append(common.body_mat(ship.block("tower", 0.8, 0.9, 0.6, 0.62, 0.66, off=(0.0, 0.06), origin=(0.0, cy, dz))))
    z2 = dz + 0.6
    by = cy - 0.04
    objects.append(common.accent_mat(ship.block("bridge", 0.74, 0.6, 0.26, 0.6, 0.34, off=(0.0, 0.08), origin=(0.0, by, z2)), accent))
    # the bridge's front face runs from y = by - 0.3 at its foot to by - 0.09 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.56, 0.08, by - 0.3 + 0.095 - 0.008, z2 + 0.12, lean=0.063), palette.AMBER))

    my = by + 0.12
    objects.append(common.trim_mat(ship.spire("mast", 0.1, 0.1, 0.8, origin=(0.0, my, z2 + 0.26))))
    radar = common.trim_mat(ship.block("radar", 0.56, 0.1, 0.07, 0.5, 0.04, origin=(0.0, my, z2 + 0.8)))
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=2.2))

    return objects
