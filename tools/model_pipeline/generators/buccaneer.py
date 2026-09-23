"""unit_defs/ship_t1.luau `buccaneer` (BAR corcrus): a cruiser, the submarine hunter.

Collider capsule(34, 34, 115): radius 5.23, height 3.09 studs. The longest of the first-tier hulls: forward the
heavy laser (weapon 1), a big team-coloured gun house with one long, heavy barrel; amidships a long armoured
citadel with the bridge at its front, a mast with a spinning radar bar and a funnel; and on the quarterdeck the
depth-charge launcher (weapon 2), a squat, sloped, team-coloured mortar house that turns toward what is in the
water. Built to the 100-triangle limit (ship_t1_common).
"""

from . import common
from . import ship_t1_common as ship

NAME = "buccaneer"
ACCENT = ship.rgb(120, 150, 196)
RADIUS, HEIGHT = 115 / 22, 34 / 11


def generate(params):
    hull = ship.Hull(10.0, 2.3, 0.74, [(0.0, 0.72), (0.22, 1.0), (0.55, 0.97), (0.8, 0.6), (1.0, 0.0)],
                     sheer=0.34, flare=0.78, rake=0.06)
    objects = [ship.body(hull.build())]
    objects.append(ship.trim(hull.build_deck()))

    # Heavy laser forward: a big sloped gun house and one long, tapering barrel.
    ty = -2.55
    tz = hull.deck_at(ty)
    house = ship.block("laser_house", 1.2, 1.3, 0.44, 0.84, 0.72, off=(0.0, 0.22))
    barrel = ship.bar("laser_barrel", 0.26, 0.24, 1.6, -0.5, 0.24, sides=4, taper=0.55)
    for p in (house, barrel):
        ship.accent_mat(p, NAME, ACCENT)
    laser = common.merge("laser", [house, barrel], origin=(0.0, ty, tz))
    objects.append(common.art_group(laser, "turret_1", pivot=True, kind="turret", weapon=1))

    # Citadel amidships, the team-coloured bridge at its front, the mast and radar, the funnel behind.
    cy = 0.35
    dz = hull.deck_at(cy)
    objects.append(ship.body(ship.block("citadel", 1.5, 3.4, 0.5, 1.2, 3.0, off=(0.0, 0.1), origin=(0.0, cy, dz))))
    z2 = dz + 0.5
    by = cy - 1.05
    objects.append(ship.accent_mat(ship.block("bridge", 1.0, 0.9, 0.42, 0.8, 0.5, off=(0.0, 0.16), origin=(0.0, by, z2)), NAME, ACCENT))
    # the bridge's front face runs from y = by - 0.45 at its foot to by - 0.09 at its top
    objects.append(ship.glow_mat(ship.front_window("windows", 0.78, 0.1, by - 0.45 + 0.171 - 0.01, z2 + 0.2, lean=0.086), NAME))
    my = by + 0.62
    objects.append(ship.trim(ship.spire("mast", 0.16, 0.16, 1.62, origin=(0.0, my, z2))))
    radar = ship.trim(ship.block("radar", 0.9, 0.14, 0.1, 0.8, 0.06, origin=(0.0, my, z2 + 1.1)))
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=1.9))
    fy = cy + 0.75
    objects.append(ship.body(ship.block("funnel", 0.62, 0.9, 0.62, 0.48, 0.64, off=(0.0, 0.2), origin=(0.0, fy, z2))))

    # Depth-charge launcher on the quarterdeck.
    dy = 3.45
    dcz = hull.deck_at(dy)
    mortar = ship.accent_mat(ship.block("depth_charges", 0.9, 0.8, 0.3, 0.7, 0.34, off=(0.0, 0.2)), NAME, ACCENT)
    mortar = common.merge("depth_charges", [mortar], origin=(0.0, dy, dcz))
    objects.append(common.art_group(mortar, "turret_2", pivot=True, kind="turret", weapon=2))

    ship.report(NAME, objects, RADIUS, HEIGHT)
    return objects
