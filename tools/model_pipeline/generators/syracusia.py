"""unit_defs/ship_t1.luau `syracusia` (BAR legnavydestro, Legion's Syracusia): a destroyer with a heat ray and a
drone carrier's flight deck.

A small carrier: a flat, dark flight deck covers the
hull from the stern almost to the bow, lopsided, with its angled landing strip overhanging the port side, and the
island (a tall block with the team-coloured bridge and a spinning radar bar) stands on its starboard edge, so from
above it is the one asymmetric ship. A team-coloured landing pad for its drone sits aft, a line of amber deck
lights runs up the strip, and on the bow ahead of the flight deck is the heat-ray turret, a team-coloured gun house
with an emitter ending in a glowing orange lens. Built to the 100-triangle limit (shared/ship_t1.py).
"""

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "syracusia"
MOUNTS = {
    1: {"pivot": (0, 1.2796, 2.8804), "muzzle": (0, 0.2639, 1.0287)},
}


def generate(params):
    accent = params["color"]
    hull = ship.Hull(7.5, 1.95, 0.72, [(0.0, 0.78), (0.25, 1.0), (0.55, 0.96), (0.8, 0.6), (1.0, 0.0)],
                     sheer=0.34, flare=0.76, rake=0.08)
    objects = [common.body_mat(hull.build())]
    objects.append(common.trim_mat(hull.build_deck()))

    # The flight deck: a slab over the hull from the stern to near the bow, its angled strip overhanging to port
    # (+X, the unit facing -Y) and its starboard edge straight, for the island.
    fz = hull.depth
    fh = 0.32
    deck = [(-0.92, 3.55), (0.9, 3.55), (1.28, -0.5), (0.6, -2.3), (-0.42, -2.3), (-0.92, -0.2)]
    objects.append(common.trim_mat(ship.prism("flight_deck", deck, fh, origin=(0.0, 0.0, fz))))
    top = fz + fh
    # the drone's landing pad aft, and the deck lights up the angled strip
    s = 0.42
    objects.append(common.accent_mat(ship.deck_panel("pad", [(0.2 - s, 2.75 - s), (0.2 + s, 2.75 - s), (0.2 + s, 2.75 + s), (0.2 - s, 2.75 + s)], top, lift=0.01), accent))
    objects.append(common.glow_mat(ship.deck_panel("strip_lights", [(0.2, 1.9), (0.3, 1.9), (0.92, -1.35), (0.82, -1.35)], top, lift=0.01), palette.AMBER))

    # The island on the starboard edge: a tall block, the bridge on it, the radar on the bridge.
    iy = 0.55
    objects.append(common.body_mat(ship.block("island", 0.46, 1.3, 0.62, 0.38, 1.0, off=(0.0, 0.08), origin=(-0.66, iy, top))))
    z2 = top + 0.62
    by = iy - 0.05
    objects.append(common.accent_mat(ship.block("bridge", 0.46, 0.8, 0.3, 0.38, 0.52, off=(0.0, 0.06), origin=(-0.66, by, z2)), accent))
    # the bridge's front face runs from y = by - 0.4 at its foot to by - 0.2 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.34, 0.08, by - 0.4 + 0.08 - 0.008, z2 + 0.12, x=-0.66, lean=0.053), palette.AMBER))
    radar = common.trim_mat(ship.block("radar", 0.8, 0.14, 0.1, 0.72, 0.06, origin=(-0.66, by + 0.1, z2 + 0.3)))
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=1.8))

    # Heat-ray turret on the bow, ahead of the flight deck: gun house and emitter (accent), and the lens (glow).
    ty = -2.8
    tz = hull.deck_at(ty)
    house = ship.block("turret_house", 0.7, 0.8, 0.34, 0.5, 0.46, off=(0.0, 0.12))
    emitter = ship.bar("turret_emitter", 0.18, 0.18, 0.64, -0.24, 0.19, taper=0.6, cap=False)
    for p in (house, emitter):
        common.accent_mat(p, accent)
    turret = common.merge("turret", [house, emitter], origin=(0.0, ty, tz))
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))
    lens = ship.point_cone("turret_lens", (0.0, ty - 0.87, tz + 0.19), (0.0, ty - 1.0, tz + 0.19), 0.08)
    common.glow_mat(lens, palette.LENS_ORANGE)
    objects.append(common.art_group(lens, "turret_1"))

    return objects
