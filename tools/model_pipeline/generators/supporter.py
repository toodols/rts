"""unit_defs/ship_t1.luau `supporter` (BAR coresupp): a light gun boat, a laser turret at each end.

The only catamaran: two slim, sharp hulls with open
water between them, bridged by a broad team-coloured deck, so from above it is a two-pronged fork. A low wheelhouse
sits in the middle of the bridging deck, and the two small laser turrets stand on its ends, the first forward
(weapon 1, offset +1.4 forward) and the second aft (weapon 2, offset -1.4). Built to the 100-triangle limit
(shared/ship_t1.py).
"""

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "supporter"
MOUNTS = {
    1: {"pivot": (0, 0.6353, 0.8556), "muzzle": (-0.0328, 0.0801, 0.6417)},
    2: {"pivot": (0, 0.6353, -1.016), "muzzle": (-0.0328, 0.0801, 0.6417)},
}
SPAN = 0.46  # each hull's centreline off the middle


def _laser_turret(prefix, swivel, accent):
    # 17 triangles: a sloped gun house and one long, thin emitter
    house = ship.block(f"{prefix}_house", 0.32, 0.38, 0.14, 0.22, 0.2, off=(0.0, 0.07))
    emitter = ship.bar(f"{prefix}_emitter", 0.07, 0.07, 0.5, -0.1, 0.08, taper=0.7)
    for p in (house, emitter):
        common.accent_mat(p, accent)
    return common.merge(prefix, [house, emitter], origin=swivel)


def generate(params):
    # the two hulls, the first of which is the footprint build.py centres on: so both straddle the middle, the
    # footprint is a thin deck plate spanning them, built first
    accent = params["color"]
    deck_z = 0.34
    plate = common.accent_mat(ship.block("bridge_deck", 2 * SPAN + 0.34, 2.3, 0.1, 2 * SPAN + 0.22, 2.2, origin=(0.0, 0.0, deck_z)), accent)
    objects = [plate]
    for side in (-1.0, 1.0):
        hull = ship.Hull(3.4, 0.44, deck_z + 0.02, [(0.0, 0.8), (0.3, 1.0), (0.65, 0.9), (1.0, 0.0)],
                         sheer=0.12, flare=0.7, rake=0.12, x=side * SPAN)
        objects.append(common.body_mat(hull.build(f"hull_{side:+.0f}")))
        objects.append(common.trim_mat(hull.build_deck(f"hull_deck_{side:+.0f}")))

    # Low wheelhouse in the middle of the deck, its windows looking forward.
    top = deck_z + 0.1
    wy = 0.12
    objects.append(common.body_mat(ship.block("wheelhouse", 0.56, 0.62, 0.2, 0.44, 0.38, off=(0.0, 0.08), origin=(0.0, wy, top))))
    # the wheelhouse's front face runs from y = wy - 0.31 at its foot to wy - 0.11 at its top
    objects.append(common.glow_mat(ship.front_window("windows", 0.42, 0.07, wy - 0.31 + 0.07 - 0.006, top + 0.07, lean=0.07), palette.AMBER))

    for name, y, weapon in (("turret_1", -0.8, 1), ("turret_2", 0.95, 2)):
        turret = _laser_turret(name, (0.0, y, top), accent)
        objects.append(common.art_group(turret, name, pivot=True, kind="turret", weapon=weapon))

    return objects
