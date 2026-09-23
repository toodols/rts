"""unit_defs/ship_t1.luau `construction_ship` (BAR corcs): the builder ship.

Collider capsule(30, 26, 47): radius 2.14, height 2.36 studs. A broad, bluff workboat: a team-coloured wheelhouse on
a deckhouse aft, a cargo hopper amidships, and forward a high-vis yellow nanolathe crane on a turntable, its boom
raised and its forearm reaching down to a glowing green emitter. The turntable, boom and emitter turn together
toward whatever the ship is building (kind = "work"), like the construction turret's head. Built to the
100-triangle limit (ship_t1_common).
"""

from . import common
from . import ship_t1_common as ship

NAME = "construction_ship"
ACCENT = ship.rgb(226, 178, 74)
RADIUS, HEIGHT = 47 / 22, 26 / 11


def generate(params):
    hull = ship.Hull(3.9, 1.5, 0.5, [(0.0, 0.86), (0.32, 1.0), (0.68, 0.86), (1.0, 0.0)], sheer=0.14, flare=0.8, rake=0.12)
    objects = [ship.body(hull.build())]
    objects.append(ship.trim(hull.build_deck()))

    # Deckhouse and wheelhouse aft, with the bridge windows looking forward over the crane.
    hy = 1.0
    dz = hull.deck_at(hy)
    objects.append(ship.body(ship.block("house", 1.0, 1.0, 0.3, 0.9, 0.84, off=(0.0, 0.05), origin=(0.0, hy, dz))))
    z2 = dz + 0.3
    wy = hy - 0.08
    objects.append(ship.accent_mat(ship.block("wheelhouse", 0.76, 0.56, 0.28, 0.62, 0.36, off=(0.0, 0.08), origin=(0.0, wy, z2)), NAME, ACCENT))
    # the wheelhouse's front face runs from y = wy - 0.28 at its foot to wy - 0.1 at its top
    objects.append(ship.glow_mat(ship.front_window("windows", 0.58, 0.09, wy - 0.28 + 0.074 - 0.008, z2 + 0.13, lean=0.058), NAME))
    objects.append(ship.trim(ship.spire("mast", 0.09, 0.09, 0.75, origin=(0.0, wy + 0.12, z2 + 0.28))))

    # Cargo hopper amidships: the metal it carries to build with.
    cy = 0.2
    objects.append(ship.body(ship.block("hopper", 0.9, 0.62, 0.2, 1.0, 0.7, origin=(0.0, cy, hull.deck_at(cy)))))

    # The nanolathe crane, built about its turntable's centre on the deck.
    ty = -0.62
    tz = hull.deck_at(ty)
    table = ship.block("crane_table", 0.56, 0.56, 0.18, 0.46, 0.46)
    shoulder = (0.0, 0.08, 0.16)
    elbow = (0.0, -0.3, 1.0)
    wrist = (0.0, -0.78, 0.56)
    boom = ship.beam("crane_boom", shoulder, elbow, 0.16, 0.14)
    fore = ship.beam("crane_fore", elbow, wrist, 0.12, 0.11, taper=0.8)
    for p in (table, boom, fore):
        ship.hivis_mat(p)
    crane = common.merge("crane", [table, boom, fore], origin=(0.0, ty, tz))
    objects.append(common.art_group(crane, "crane", pivot=True, kind="work"))
    tip = (0.0, ty + wrist[1] - 0.16, tz + wrist[2] - 0.14)
    emitter = ship.point_cone("emitter", (0.0, ty + wrist[1] + 0.02, tz + wrist[2] + 0.02), tip, 0.1)
    ship.glow_mat(emitter, NAME, ship.NANO_GREEN)
    objects.append(common.art_group(emitter, "crane"))

    ship.report(NAME, objects, RADIUS, HEIGHT)
    return objects
