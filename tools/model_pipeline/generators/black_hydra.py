"""unit_defs/ship_t2.luau `black_hydra` (BAR corblackhy): the flagship.

The biggest ship: a long, broad hull with a sharp
clipper bow. On the foredeck the great plasma battery (weapon 1), a big, team-coloured gun house with two long, heavy
barrels; behind it a massive citadel running most of the way aft, its tower forward carrying the lit bridge and a tall
mast. A green heavy laser turret stands on the citadel's roof (weapon 2) and another on the quarterdeck (weapon 4),
each small and team-coloured with one short barrel; the third laser and the two missile launchers fire from the
citadel. Built to the 100-triangle limit (shared/ship_t1.py).
"""

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "black_hydra"
MOUNTS = {
    1: {"pivot": (0, 1.9081, 3.2127), "muzzle": (-0.6848, 0.3296, 4.1427)},
    2: {"pivot": (0, 2.7814, -3.8891), "muzzle": (-0.1278, 0.2555, 1.7755)},
    4: {"pivot": (0, 1.7512, -6.7636), "muzzle": (-0.1278, 0.2555, 1.7755)},
}


def _laser(name, weapon, y, z, accent):
    """A small laser turret with one short barrel: 16 triangles."""
    house = ship.block(f"{name}_house", 0.7, 0.7, 0.3, 0.5, 0.5, off=(0.0, 0.08))
    barrel = ship.bar(f"{name}_barrel", 0.16, 0.16, 0.8, -0.25, 0.18, sides=3, taper=0.7, cap=False)
    for p in (house, barrel):
        common.accent_mat(p, accent)
    turret = common.merge(name, [house, barrel], origin=(0.0, y, z))
    return common.art_group(turret, f"turret_{weapon}", pivot=True, kind="turret", weapon=weapon)


def generate(params):
    accent = params["color"]
    hull = ship.Hull(10.0, 2.3, 0.85, [(0.0, 0.8), (0.2, 1.0), (0.65, 0.95), (1.0, 0.0)],
                     sheer=0.4, flare=0.78, rake=0.1, stern_rake=0.02)
    objects = [common.body_mat(hull.build())]
    objects.append(common.trim_mat(hull.build_deck()))

    # A massive citadel amidships and aft, and its tower forward with the bridge and the mast.
    cy = 1.2
    dz = hull.deck_at(cy)
    objects.append(common.body_mat(ship.block("citadel", 1.6, 3.6, 0.5, 1.3, 3.2, off=(0.0, 0.1), origin=(0.0, cy, dz))))
    ty = cy - 1.0
    tz = dz + 0.5
    objects.append(common.body_mat(ship.block("tower", 0.9, 1.0, 0.7, 0.6, 0.7, off=(0.0, 0.1), origin=(0.0, ty, tz))))
    # the tower's front face runs from y = ty - 0.5 at its foot to ty - 0.25 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.62, 0.12, ty - 0.5 + 0.18 - 0.01, tz + 0.5, lean=0.04), palette.AMBER))
    objects.append(common.trim_mat(ship.spire("mast", 0.2, 0.2, 1.5, origin=(0.0, ty + 0.2, tz + 0.68))))

    # The plasma battery on the foredeck: a big house and two long, heavy barrels.
    by = -1.9
    house = ship.block("battery_house", 1.1, 1.2, 0.45, 0.9, 0.9, off=(0.0, 0.15))
    barrels = [ship.bar(f"battery_barrel_{i}", 0.2, 0.2, 2.0, -0.45, 0.24, x=x, sides=3, taper=0.8, cap=False)
               for i, x in enumerate((-0.22, 0.22))]
    for p in [house] + barrels:
        common.accent_mat(p, accent)
    battery = common.merge("battery", [house] + barrels, origin=(0.0, by, hull.deck_at(by)))
    objects.append(common.art_group(battery, "turret_1", pivot=True, kind="turret", weapon=1))

    # The lasers: one on the citadel's roof, one on the quarterdeck.
    objects.append(_laser("roof_laser", 2, cy + 1.1, dz + 0.5, accent))
    objects.append(_laser("aft_laser", 4, 4.0, hull.deck_at(4.0), accent))

    return objects
