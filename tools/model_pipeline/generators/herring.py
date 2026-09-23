"""unit_defs/ship_t1.luau `herring` (BAR corpt): a light missile corvette with two missile racks.

Collider capsule(20, 20, 60): radius 2.73, height 1.82 studs. A slim, sharp corvette with a small bridge amidships
under a mast and a spinning radar bar, and a missile rack at each end, each its own turret: forward the anti-air
rack (weapon 1, offset +1 forward), a pair of launch cells pitched steeply up; aft the anti-ground rack (weapon 2,
offset -1), a wide, flat twin canister pitched low. Built to the 100-triangle limit (ship_t1_common).
"""

import math

from . import common
from . import ship_t1_common as ship

NAME = "herring"
ACCENT = ship.rgb(120, 150, 196)
RADIUS, HEIGHT = 60 / 22, 20 / 11


def _rack(prefix, swivel, w, h, length, pitch, lift):
    """A missile rack on a squat pedestal: 22 triangles. The launcher box is pitched `pitch` degrees up about its
    middle, which sits `lift` above the deck."""
    base = ship.block(f"{prefix}_base", 0.34, 0.34, lift * 0.8, 0.26, 0.26)
    box = ship.loft(f"{prefix}_box", [
        [(-w / 2, length / 2, -h / 2), (w / 2, length / 2, -h / 2), (w / 2, length / 2, h / 2), (-w / 2, length / 2, h / 2)],
        [(-w / 2, -length / 2, -h / 2), (w / 2, -length / 2, -h / 2), (w / 2, -length / 2, h / 2), (-w / 2, -length / 2, h / 2)],
    ], cap_first=True, cap_last=True)
    box.rotation_euler = (math.radians(-pitch), 0.0, 0.0)
    box.location = (0.0, 0.0, lift)
    for p in (base, box):
        ship.accent_mat(p, NAME, ACCENT)
    return common.merge(prefix, [base, box], origin=swivel)


def generate(params):
    hull = ship.Hull(5.2, 1.12, 0.44, [(0.0, 0.7), (0.3, 1.0), (0.62, 0.9), (1.0, 0.0)], sheer=0.2, rake=0.09)
    objects = [ship.body(hull.build())]
    objects.append(ship.trim(hull.build_deck()))

    # Deckhouse and bridge amidships.
    hy = 0.1
    dz = hull.deck_at(hy)
    objects.append(ship.body(ship.block("house", 0.72, 1.2, 0.26, 0.6, 0.96, off=(0.0, 0.08), origin=(0.0, hy, dz))))
    z2 = dz + 0.26
    by = hy - 0.28
    objects.append(ship.accent_mat(ship.block("bridge", 0.56, 0.5, 0.24, 0.44, 0.28, off=(0.0, 0.08), origin=(0.0, by, z2)), NAME, ACCENT))
    # the bridge's front face runs from y = by - 0.25 at its foot to by - 0.06 at its top
    objects.append(ship.glow_mat(ship.front_window("windows", 0.42, 0.07, by - 0.25 + 0.087 - 0.008, z2 + 0.11, lean=0.056), NAME))

    my = by + 0.4
    objects.append(ship.trim(ship.spire("mast", 0.09, 0.09, 0.85, origin=(0.0, my, z2))))
    radar = ship.trim(ship.block("radar", 0.44, 0.08, 0.06, 0.4, 0.04, origin=(0.0, my, z2 + 0.6)))
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=2.8))

    # Forward anti-air cells, pitched steeply up; aft anti-ground canisters, wide and low.
    ay = -1.3
    aa = _rack("turret_1", (0.0, ay, hull.deck_at(ay)), 0.3, 0.22, 0.52, 50.0, 0.2)
    objects.append(common.art_group(aa, "turret_1", pivot=True, kind="turret", weapon=1))
    gy = 1.45
    ag = _rack("turret_2", (0.0, gy, hull.deck_at(gy)), 0.46, 0.14, 0.72, 14.0, 0.16)
    objects.append(common.art_group(ag, "turret_2", pivot=True, kind="turret", weapon=2))

    ship.report(NAME, objects, RADIUS, HEIGHT)
    return objects
