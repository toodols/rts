"""unit_defs/ship_t1.luau `syracusia` (BAR legnavydestro, Legion's Syracusia): a destroyer with a heat ray and a
drone carrier's flight deck.

Collider capsule(35, 50, 86): radius 3.91, height 4.55 studs. A big, high-sided hull: forward the heat-ray turret, a
team-coloured gun house with a long emitter ending in a glowing orange lens; amidships a tall stepped tower with the
bridge, a high mast and a spinning radar bar; aft a raised hangar whose roof is the drone's team-coloured landing
pad. Built to the 100-triangle limit (ship_t1_common).
"""

from . import common
from . import ship_t1_common as ship

NAME = "syracusia"
ACCENT = ship.rgb(196, 140, 84)
RADIUS, HEIGHT = 86 / 22, 50 / 11


def generate(params):
    hull = ship.Hull(7.5, 1.95, 0.72, [(0.0, 0.78), (0.25, 1.0), (0.55, 0.96), (0.8, 0.6), (1.0, 0.0)],
                     sheer=0.34, flare=0.76, rake=0.08)
    objects = [ship.body(hull.build())]
    objects.append(ship.trim(hull.build_deck()))

    # Heat-ray turret forward: gun house and emitter (accent), and the lens at its tip (glow).
    ty = -1.85
    tz = hull.deck_at(ty)
    house = ship.block("turret_house", 0.9, 1.0, 0.36, 0.64, 0.56, off=(0.0, 0.16))
    emitter = ship.bar("turret_emitter", 0.2, 0.2, 1.05, -0.3, 0.2, taper=0.6, cap=False)
    for p in (house, emitter):
        ship.accent_mat(p, NAME, ACCENT)
    turret = common.merge("turret", [house, emitter], origin=(0.0, ty, tz))
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))
    lens = ship.point_cone("turret_lens", (0.0, ty - 1.33, tz + 0.2), (0.0, ty - 1.5, tz + 0.2), 0.09)
    ship.glow_mat(lens, NAME, ship.GLOW_ORANGE)
    objects.append(common.art_group(lens, "turret_1"))

    # Tower amidships: a broad sloped base, a team-coloured bridge block on it, and the mast.
    cy = -0.1
    dz = hull.deck_at(cy)
    objects.append(ship.body(ship.block("tower", 1.3, 1.9, 0.6, 1.0, 1.4, off=(0.0, 0.12), origin=(0.0, cy, dz))))
    z2 = dz + 0.6
    by = cy - 0.12
    objects.append(ship.accent_mat(ship.block("bridge", 0.92, 0.95, 0.5, 0.7, 0.55, off=(0.0, 0.16), origin=(0.0, by, z2)), NAME, ACCENT))
    # the bridge's front face runs from y = by - 0.475 at its foot to by - 0.115 at its top
    objects.append(ship.glow_mat(ship.front_window("windows", 0.66, 0.12, by - 0.475 + 0.18 - 0.01, z2 + 0.25, lean=0.086), NAME))
    my = by + 0.25
    objects.append(ship.trim(ship.spire("mast", 0.16, 0.16, 2.1, origin=(0.0, my, z2 + 0.5))))
    radar = ship.trim(ship.block("radar", 0.9, 0.14, 0.1, 0.8, 0.06, origin=(0.0, my, z2 + 1.6)))
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=1.8))

    # Hangar aft, its roof the drone's landing pad.
    hy = 2.1
    hz = hull.deck_at(hy)
    objects.append(ship.body(ship.block("hangar", 1.3, 1.5, 0.42, 1.24, 1.4, off=(0.0, 0.02), origin=(0.0, hy, hz))))
    s = 0.46
    objects.append(ship.accent_mat(ship.deck_panel("pad", [(-s, hy - s), (s, hy - s), (s, hy + s), (-s, hy + s)], hz + 0.42, lift=0.01), NAME, ACCENT))

    ship.report(NAME, objects, RADIUS, HEIGHT)
    return objects
