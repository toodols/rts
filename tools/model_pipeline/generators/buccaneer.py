"""unit_defs/ship_t1.luau `buccaneer` (BAR corcrus): a cruiser, the submarine hunter.

The only trimaran: a long, narrow centre hull with a
slim outrigger either side of its after half, the three tied together by a broad team-coloured crossbeam, so from
above it is a cross, a sword with its guard. Forward the heavy laser (weapon 1), a big team-coloured gun house with
one long, heavy barrel; amidships a long, low citadel with the bridge windows at its front and a tall mast; and on
the quarterdeck the depth-charge launcher (weapon 2), a squat, sloped, team-coloured mortar house that turns toward
what is in the water. Built to the 100-triangle limit (shared/ship_t1.py).
"""

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "buccaneer"
MOUNTS = {
    1: {"pivot": (0, 0.8462, 2.5091), "muzzle": (-0.0747, 0.1764, 2.1955)},
    2: {"pivot": (0, 0.7504, -4.0773), "muzzle": (-0.4177, 0, 0.4182)},
}
OUTRIGGER_X = 1.3


def generate(params):
    accent = params["color"]
    hull = ship.Hull(10.0, 1.5, 0.74, [(0.0, 0.8), (0.3, 1.0), (0.7, 0.86), (1.0, 0.0)], sheer=0.34, flare=0.76, rake=0.06)
    objects = [common.body_mat(hull.build())]
    objects.append(common.trim_mat(hull.build_deck()))

    # The outriggers along the after half, lower than the centre hull.
    oy = 2.1
    for side in (-1.0, 1.0):
        rig = ship.Hull(4.4, 0.36, 0.42, [(0.0, 0.7), (0.4, 1.0), (1.0, 0.0)], sheer=0.06, flare=0.7, rake=0.12,
                        x=side * OUTRIGGER_X, y=oy)
        objects.append(common.body_mat(rig.build(f"outrigger_{side:+.0f}")))
        objects.append(common.trim_mat(rig.build_deck(f"outrigger_deck_{side:+.0f}")))
    # the crossbeam tying them to the centre hull: a broad team-coloured wing just proud of the main deck
    wy = 1.7
    span = 2 * OUTRIGGER_X + 0.3
    objects.append(common.accent_mat(ship.block("crossbeam", span, 1.3, 0.38, span - 0.1, 1.1, origin=(0.0, wy, 0.42)), accent))

    # Heavy laser forward: a big sloped gun house and one long, tapering barrel.
    ty = -2.4
    tz = hull.deck_at(ty)
    house = ship.block("laser_house", 1.1, 1.3, 0.44, 0.78, 0.72, off=(0.0, 0.22))
    barrel = ship.bar("laser_barrel", 0.26, 0.24, 1.6, -0.5, 0.24, sides=3, taper=0.55)
    for p in (house, barrel):
        common.accent_mat(p, accent)
    laser = common.merge("laser", [house, barrel], origin=(0.0, ty, tz))
    objects.append(common.art_group(laser, "turret_1", pivot=True, kind="turret", weapon=1))

    # A long, low citadel amidships, its bridge windows at the front and the mast behind them.
    cy = -0.35
    dz = hull.deck_at(cy)
    objects.append(common.body_mat(ship.block("citadel", 1.1, 2.3, 0.62, 0.8, 1.8, off=(0.0, 0.14), origin=(0.0, cy, dz))))
    # the citadel's front face runs from y = cy - 1.15 at its foot to cy - 0.76 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.74, 0.1, cy - 1.15 + 0.29 - 0.01, dz + 0.46, lean=0.063), palette.AMBER))
    objects.append(common.trim_mat(ship.spire("mast", 0.18, 0.18, 1.7, origin=(0.0, cy + 0.1, dz + 0.6))))

    # Depth-charge launcher on the quarterdeck.
    dy = 3.9
    dcz = hull.deck_at(dy)
    mortar = common.accent_mat(ship.block("depth_charges", 0.8, 0.8, 0.3, 0.6, 0.34, off=(0.0, 0.2)), accent)
    mortar = common.merge("depth_charges", [mortar], origin=(0.0, dy, dcz))
    objects.append(common.art_group(mortar, "turret_2", pivot=True, kind="turret", weapon=2))

    return objects
