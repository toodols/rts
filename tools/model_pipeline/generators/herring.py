"""unit_defs/ship_t1.luau `herring` (BAR corpt): a light missile corvette with two missile racks.

A stealth corvette: a long dart of a hull, widest at
the stern and tapering straight to the bow, almost all of it covered by one long, faceted, team-coloured
superstructure, so from above it is a single pointed diamond. A stub mast with a spinning radar bar rises from the
superstructure's ridge, and a dark missile rack sits at each end, each its own turret: forward the anti-air rack
(weapon 1, offset +1 forward), a pair of launch cells pitched steeply up; aft the anti-ground rack (weapon 2,
offset -1), a wide, flat twin canister pitched low. Built to the 100-triangle limit (shared/ship_t1.py).
"""

import math

from .shared import common
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "herring"
MOUNTS = {
    1: {"pivot": (0, 0.5863, 2.0583), "muzzle": (-0.1743, 0.3446, 0.231)},
    2: {"pivot": (0, 0.4723, -2.0995), "muzzle": (-0.3113, 0.1973, 0.327)},
}


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
        common.trim_mat(p)
    return common.merge(prefix, [base, box], origin=swivel)


def generate(params):
    # a dart: full width at the stern, straight sides running in to the bow
    accent = params["color"]
    hull = ship.Hull(5.3, 1.46, 0.4, [(0.0, 0.84), (0.25, 1.0), (1.0, 0.0)], sheer=0.16, flare=0.8, rake=0.07)
    objects = [common.body_mat(hull.build())]
    objects.append(common.trim_mat(hull.build_deck()))

    # The stealth superstructure: a long six-sided faceted block, pointed at both ends, its sides sloping in to a
    # narrow ridge. Built on the deck's height at its stern end; the sheer forward buries its foot a little.
    y0, y1 = -1.4, 1.5  # its bow and stern points
    half = 0.47
    base_z = hull.deck_at(y1) - 0.02
    outline = [(0.0, y0), (half, y0 + 1.1), (half, y1 - 0.5), (0.0, y1), (-half, y1 - 0.5), (-half, y0 + 1.1)]
    ridge = [(0.0, y0 + 0.7), (0.15, y0 + 1.25), (0.15, y1 - 0.55), (0.0, y1 - 0.25), (-0.15, y1 - 0.55), (-0.15, y0 + 1.25)]
    h = 0.58
    objects.append(common.accent_mat(ship.prism("superstructure", outline, h, top_outline=ridge, origin=(0.0, 0.0, base_z)), accent))
    my = 0.15
    top = base_z + h
    objects.append(common.trim_mat(ship.spire("mast", 0.1, 0.1, 0.6, origin=(0.0, my, top - 0.02))))
    radar = common.trim_mat(ship.block("radar", 0.5, 0.08, 0.06, 0.44, 0.04, origin=(0.0, my, top + 0.36)))
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=2.8))

    # Forward anti-air cells, pitched steeply up; aft anti-ground canisters, wide and low.
    ay = -2.0
    aa = _rack("turret_1", (0.0, ay, hull.deck_at(ay)), 0.28, 0.2, 0.46, 50.0, 0.18)
    objects.append(common.art_group(aa, "turret_1", pivot=True, kind="turret", weapon=1))
    gy = 2.04
    ag = _rack("turret_2", (0.0, gy, hull.deck_at(gy)), 0.5, 0.14, 0.62, 14.0, 0.16)
    objects.append(common.art_group(ag, "turret_2", pivot=True, kind="turret", weapon=2))

    return objects
