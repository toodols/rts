"""unit_defs/ship_t2.luau `despot` (BAR corbats): the battleship.

A broad, heavy hull with a blunt, flared bow, the widest
of the ships. Forward the main battery (weapons 1 to 3, whose one turret weapon 1 turns): a big, low, team-coloured
gun house with three long barrels side by side. Amidships a stepped citadel, lit bridge windows across its front and
a tall mast behind them; aft the heavy laser (weapon 4), a small team-coloured turret with one short, thick barrel.
Built to the 100-triangle limit (shared/ship_t1.py).
"""

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "despot"
MOUNTS = {
    1: {"pivot": (0, 1.4546, 2.96), "muzzle": (-0.8065, 0.3602, 3.2964)},
    4: {"pivot": (0, 1.3341, -4.44), "muzzle": (-0.1271, 0.2168, 1.6145)},
}


def generate(params):
    accent = params["color"]
    hull = ship.Hull(10.0, 2.6, 0.8, [(0.0, 0.78), (0.25, 1.0), (0.7, 0.92), (0.9, 0.55), (1.0, 0.0)],
                     sheer=0.3, flare=0.8, rake=0.07, stern_rake=0.02)
    objects = [common.body_mat(hull.build())]
    objects.append(common.trim_mat(hull.build_deck()))

    # The main battery forward: a wide, low, sloped gun house and three long barrels abreast.
    ty = -2.2
    house = ship.block("battery_house", 1.5, 1.4, 0.5, 1.2, 1.0, off=(0.0, 0.18))
    barrels = [ship.bar(f"battery_barrel_{i}", 0.16, 0.16, 1.9, -0.55, 0.28, x=x, sides=3, taper=0.8, cap=False)
               for i, x in enumerate((-0.38, 0.0, 0.38))]
    for p in [house] + barrels:
        common.accent_mat(p, accent)
    battery = common.merge("battery", [house] + barrels, origin=(0.0, ty, hull.deck_at(ty)))
    objects.append(common.art_group(battery, "turret_1", pivot=True, kind="turret", weapon=1))

    # A stepped citadel amidships, its bridge windows forward and the mast behind.
    cy = 0.5
    dz = hull.deck_at(cy)
    objects.append(common.body_mat(ship.block("citadel", 1.5, 2.6, 0.55, 1.1, 2.0, off=(0.0, 0.15), origin=(0.0, cy, dz))))
    objects.append(common.body_mat(ship.block("bridge", 0.9, 1.0, 0.45, 0.7, 0.8, off=(0.0, 0.05), origin=(0.0, cy - 0.35, dz + 0.55))))
    # the bridge's front face runs from y = cy - 0.85 at its foot to cy - 0.7 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.66, 0.12, cy - 0.85 + 0.2 - 0.01, dz + 0.55 + 0.25, lean=0.04), palette.AMBER))
    objects.append(common.trim_mat(ship.spire("mast", 0.2, 0.2, 1.6, origin=(0.0, cy + 0.2, dz + 0.98))))

    # The heavy laser aft: a small turret with one short, thick barrel.
    ly = 3.3
    laser_house = ship.block("laser_house", 0.8, 0.8, 0.34, 0.6, 0.55, off=(0.0, 0.1))
    laser_barrel = ship.bar("laser_barrel", 0.2, 0.2, 0.9, -0.3, 0.2, sides=3, taper=0.7, cap=False)
    for p in (laser_house, laser_barrel):
        common.accent_mat(p, accent)
    laser = common.merge("laser", [laser_house, laser_barrel], origin=(0.0, ly, hull.deck_at(ly)))
    objects.append(common.art_group(laser, "turret_4", pivot=True, kind="turret", weapon=4))

    return objects
