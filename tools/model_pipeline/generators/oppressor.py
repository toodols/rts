"""unit_defs/ship_t1.luau `oppressor` (BAR corroy, Cortex's Oppressor): the destroyer, with a heavy plasma cannon and
a depth charge launcher.

A long, lean destroyer with a sharp, high bow. Forward, on a raised barbette, the heavy cannon (weapon 1): a broad,
sloped, team-coloured gun house with two long barrels, which fire in turn. Amidships a stepped superstructure, a wide
lower deckhouse and the team-coloured bridge on it, with a raked funnel behind; on the stern the depth charge rack,
a low team-coloured wedge that does not turn (BAR fires it nearly all round). Built to the 100-triangle limit
(shared/ship_t1.py).
"""

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "oppressor"
MOUNTS = {
    1: {"pivot": (0, 1.1859, 1.914), "muzzle": (-0.2965, 0.1523, 1.5614)},
}


def _cannon(swivel, accent):
    """The heavy cannon: a broad, sloped gun house (accent) and two long barrels (trim)."""
    house = common.accent_mat(ship.block("turret_house", 0.9, 1.05, 0.32, 0.66, 0.7, off=(0.0, 0.14)), accent)
    head = common.merge("turret", [house], origin=swivel)
    guns = []
    for side in (-1.0, 1.0):
        guns.append(common.trim_mat(ship.bar("gun", 0.12, 0.12, 1.15, -0.4, 0.16, x=side * 0.17, taper=0.8)))
    return head, common.merge("turret_guns", guns, origin=swivel)


def generate(params):
    accent = params["color"]
    hull = ship.Hull(7.4, 1.6, 0.6, [(0.0, 0.7), (0.18, 1.0), (0.55, 0.98), (0.8, 0.6), (1.0, 0.0)],
                     sheer=0.36, flare=0.78, rake=0.14)
    objects = [common.body_mat(hull.build())]
    objects.append(common.trim_mat(hull.build_deck()))

    # The barbette forward, and the cannon on it.
    ty = -1.9
    tz = hull.deck_at(ty)
    objects.append(common.body_mat(ship.block("barbette", 0.72, 0.72, 0.16, 0.66, 0.66, origin=(0.0, ty, tz))))
    head, guns = _cannon((0.0, ty, tz + 0.16), accent)
    objects.append(common.art_group(head, "turret_1", pivot=True, kind="turret", weapon=1))
    objects.append(common.art_group(guns, "turret_1"))

    # The superstructure amidships: a wide deckhouse, the bridge on its forward half, the funnel behind.
    cy = 0.3
    dz = hull.deck_at(cy)
    objects.append(common.body_mat(ship.block("deckhouse", 1.0, 2.0, 0.42, 0.82, 1.7, off=(0.0, 0.1), origin=(0.0, cy, dz))))
    z2 = dz + 0.42
    by = cy - 0.3
    objects.append(common.accent_mat(ship.block("bridge", 0.76, 0.9, 0.3, 0.62, 0.6, off=(0.0, 0.1), origin=(0.0, by, z2)), accent))
    # the bridge's front face runs from y = by - 0.45 at its foot to by - 0.2 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.58, 0.08, by - 0.45 + 0.1 - 0.008, z2 + 0.12, lean=0.083), palette.AMBER))
    fy = cy + 0.65
    objects.append(common.trim_mat(ship.block("funnel", 0.4, 0.5, 0.55, 0.3, 0.34, off=(0.0, 0.14), origin=(0.0, fy, z2))))

    # The depth charge rack on the stern.
    ry = 2.75
    rz = hull.deck_at(ry)
    objects.append(common.accent_mat(ship.prism("rack", [(-0.36, 0.34), (0.0, -0.4), (0.36, 0.34)], 0.16, origin=(0.0, ry, rz)), accent))

    return objects
