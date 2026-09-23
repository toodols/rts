"""unit_defs/ship_t1.luau `riptide` (BAR corpship): a gun ship with one light plasma cannon.

Collider capsule(25, 24, 71): radius 3.23, height 2.18 studs. A long, low armoured hull whose one big gun dominates
it: a wide twin plasma-cannon turret forward, a long sloped citadel amidships with a team-coloured bridge at its
front, a mast with a spinning radar bar, and a raked funnel. Built to the 100-triangle limit (ship_t1_common).
"""

from . import common
from . import ship_t1_common as ship

NAME = "riptide"
ACCENT = ship.rgb(120, 150, 196)
RADIUS, HEIGHT = 71 / 22, 24 / 11


def _cannon(swivel):
    """The twin plasma cannon: a wide sloped gun house (accent) and two long barrels (trim). 24 triangles."""
    house = ship.accent_mat(ship.block("turret_house", 0.74, 0.86, 0.28, 0.54, 0.46, off=(0.0, 0.14)), NAME, ACCENT)
    head = common.merge("turret", [house], origin=swivel)
    guns = []
    for side in (-1.0, 1.0):
        guns.append(ship.trim(ship.bar("gun", 0.12, 0.11, 0.86, -0.3, 0.14, x=side * 0.16, taper=0.75)))
    return head, common.merge("turret_guns", guns, origin=swivel)


def generate(params):
    hull = ship.Hull(6.1, 1.42, 0.55, [(0.0, 0.74), (0.25, 1.0), (0.55, 0.96), (0.8, 0.58), (1.0, 0.0)],
                     sheer=0.22, rake=0.07)
    objects = [ship.body(hull.build())]
    objects.append(ship.trim(hull.build_deck()))

    ty = -1.45
    head, guns = _cannon((0.0, ty, hull.deck_at(ty)))
    objects.append(common.art_group(head, "turret_1", pivot=True, kind="turret", weapon=1))
    objects.append(common.art_group(guns, "turret_1"))

    # Citadel: a long, low armoured block with sloped sides, the bridge at its front end.
    cy = 0.45
    dz = hull.deck_at(cy)
    objects.append(ship.body(ship.block("citadel", 1.0, 2.1, 0.34, 0.8, 1.8, off=(0.0, 0.08), origin=(0.0, cy, dz))))
    z2 = dz + 0.34
    by = cy - 0.55
    objects.append(ship.accent_mat(ship.block("bridge", 0.7, 0.62, 0.3, 0.54, 0.36, off=(0.0, 0.1), origin=(0.0, by, z2)), NAME, ACCENT))
    # the bridge's front face runs from y = by - 0.31 at its foot to by - 0.08 at its top
    objects.append(ship.glow_mat(ship.front_window("windows", 0.5, 0.08, by - 0.31 + 0.107 - 0.008, z2 + 0.14, lean=0.061), NAME))

    # Mast and radar, just behind the bridge.
    my = by + 0.3
    objects.append(ship.trim(ship.spire("mast", 0.1, 0.1, 0.95, origin=(0.0, my, z2))))
    radar = ship.trim(ship.block("radar", 0.56, 0.1, 0.07, 0.5, 0.04, origin=(0.0, my, z2 + 0.72)))
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=2.2))

    # Raked funnel on the citadel's aft half.
    fy = cy + 0.5
    objects.append(ship.body(ship.block("funnel", 0.38, 0.5, 0.42, 0.3, 0.34, off=(0.0, 0.14), origin=(0.0, fy, z2))))

    ship.report(NAME, objects, RADIUS, HEIGHT)
    return objects
