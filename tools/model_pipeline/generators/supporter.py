"""unit_defs/ship_t1.luau `supporter` (BAR coresupp): a light gun boat, a laser turret at each end.

Collider capsule(20, 16, 40): radius 1.82, height 1.45 studs. A low, fast, sharp-bowed hull with a small two-tier
bridge amidships under a mast and a spinning radar bar, and two small laser turrets, the first forward (weapon 1,
offset +1.4 forward) and the second aft (weapon 2, offset -1.4). Built to the 100-triangle limit
(ship_t1_common).
"""

from . import common
from . import ship_t1_common as ship

NAME = "supporter"
ACCENT = ship.rgb(198, 86, 72)
RADIUS, HEIGHT = 40 / 22, 16 / 11


def _laser_turret(prefix, swivel):
    # 17 triangles: a sloped gun house and one long, thin emitter
    house = ship.block(f"{prefix}_house", 0.3, 0.36, 0.13, 0.22, 0.2, off=(0.0, 0.07))
    emitter = ship.bar(f"{prefix}_emitter", 0.06, 0.06, 0.46, -0.1, 0.07, taper=0.7)
    for p in (house, emitter):
        ship.accent_mat(p, NAME, ACCENT)
    return common.merge(prefix, [house, emitter], origin=swivel)


def generate(params):
    hull = ship.Hull(3.36, 0.96, 0.42, [(0.0, 0.7), (0.3, 1.0), (0.6, 0.92), (1.0, 0.0)], sheer=0.16, rake=0.1)
    objects = [ship.body(hull.build())]
    objects.append(ship.trim(hull.build_deck()))

    # Bridge: a sloped deckhouse and a team-coloured wheelhouse on it, with its window strip.
    by = 0.0
    dz = hull.deck_at(by)
    objects.append(ship.body(ship.block("house", 0.58, 0.9, 0.24, 0.48, 0.66, off=(0.0, 0.1), origin=(0.0, by, dz))))
    wz = dz + 0.24
    wy = by - 0.04
    objects.append(ship.accent_mat(ship.block("wheelhouse", 0.42, 0.4, 0.2, 0.34, 0.24, off=(0.0, 0.06), origin=(0.0, wy, wz)), NAME, ACCENT))
    # the wheelhouse's front face runs from y = wy - 0.2 at its foot to wy - 0.06 at its top
    objects.append(ship.glow_mat(ship.front_window("windows", 0.34, 0.07, wy - 0.2 + 0.056 - 0.006, wz + 0.08, lean=0.049), NAME))

    # Mast behind the wheelhouse, with a radar bar spinning at its top.
    my = wy + 0.17
    objects.append(ship.trim(ship.spire("mast", 0.07, 0.07, 0.6, origin=(0.0, my, wz))))
    radar = ship.trim(ship.block("radar", 0.34, 0.06, 0.05, 0.3, 0.03, origin=(0.0, my, wz + 0.46)))
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=2.5))

    for name, y, weapon in (("turret_1", -0.95, 1), ("turret_2", 1.1, 2)):
        turret = _laser_turret(name, (0.0, y, hull.deck_at(y)))
        objects.append(common.art_group(turret, name, pivot=True, kind="turret", weapon=weapon))

    ship.report(NAME, objects, RADIUS, HEIGHT)
    return objects
