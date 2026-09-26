"""unit_defs/ship_t1.luau `construction_ship` (BAR corcs): the builder ship.

A square-bowed work barge whose whole deck is the
builders' high-vis yellow, crossed by black hazard stripes, so at any distance it reads as the one yellow ship: a
team-coloured wheelhouse on a deckhouse right aft, a cargo hopper amidships, and forward a nanolathe crane on a
turntable, its boom raised and its forearm reaching down to a glowing green emitter. The turntable, boom and emitter
turn together toward whatever the ship is building (kind = "work"), like the construction turret's head. Built to
the 100-triangle limit (shared/ship_t1.py).
"""

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "construction_ship"


def generate(params):
    # nearly rectangular: full width almost to the bow, which closes in a short, blunt point
    accent = params["color"]
    hull = ship.Hull(3.9, 1.72, 0.46, [(0.0, 0.94), (0.2, 1.0), (0.84, 1.0), (0.96, 0.62), (1.0, 0.0)],
                     sheer=0.08, flare=0.86, rake=0.05)
    objects = [common.body_mat(hull.build())]
    objects.append(common.hivis_mat(hull.build_deck()))

    # hazard stripes across the deck, raked back from the centreline
    for k, y in enumerate((-0.4, 0.02)):
        z = max(hull.deck_at(y - 0.3), hull.deck_at(y + 0.3))
        w = hull.half_width(y) - 0.04
        for side in (-1.0, 1.0):
            pts = [(side * w, y + 0.1), (0.0, y - 0.12), (0.0, y + 0.04), (side * w, y + 0.26)]
            objects.append(common.trim_mat(ship.deck_panel(f"stripe_{k}_{side:+.0f}", pts, z, lift=0.025)))

    # Deckhouse and wheelhouse right aft, with the bridge windows looking forward over the crane.
    hy = 1.36
    dz = hull.deck_at(hy)
    objects.append(common.body_mat(ship.block("house", 1.2, 0.84, 0.28, 1.08, 0.7, off=(0.0, 0.05), origin=(0.0, hy, dz))))
    z2 = dz + 0.28
    wy = hy - 0.02
    objects.append(common.accent_mat(ship.block("wheelhouse", 0.84, 0.54, 0.3, 0.7, 0.34, off=(0.0, 0.08), origin=(0.0, wy, z2)), accent))
    # the wheelhouse's front face runs from y = wy - 0.27 at its foot to wy - 0.09 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.64, 0.09, wy - 0.27 + 0.078 - 0.008, z2 + 0.13, lean=0.054), palette.AMBER))
    objects.append(common.trim_mat(ship.spire("mast", 0.1, 0.1, 0.8, origin=(0.0, wy + 0.12, z2 + 0.3))))

    # Cargo hopper amidships: the metal it carries to build with.
    cy = 0.62
    objects.append(common.body_mat(ship.block("hopper", 0.96, 0.52, 0.22, 1.08, 0.62, origin=(0.0, cy, hull.deck_at(cy)))))

    # The nanolathe crane, built about its turntable's centre on the deck.
    ty = -0.95
    tz = hull.deck_at(ty)
    table = ship.block("crane_table", 0.6, 0.6, 0.18, 0.5, 0.5)
    shoulder = (0.0, 0.1, 0.16)
    elbow = (0.0, -0.22, 1.1)
    wrist = (0.0, -0.74, 0.62)
    boom = ship.beam("crane_boom", shoulder, elbow, 0.18, 0.16)
    fore = ship.beam("crane_fore", elbow, wrist, 0.13, 0.12, taper=0.8)
    for p in (table, boom, fore):
        common.hivis_mat(p)
    crane = common.merge("crane", [table, boom, fore], origin=(0.0, ty, tz))
    objects.append(common.art_group(crane, "crane", pivot=True, kind="work"))
    tip = (0.0, ty + wrist[1] - 0.16, tz + wrist[2] - 0.14)
    emitter = ship.point_cone("emitter", (0.0, ty + wrist[1] + 0.02, tz + wrist[2] + 0.02), tip, 0.1)
    common.glow_mat(emitter, palette.NANO)
    objects.append(common.art_group(emitter, "crane"))

    return objects
