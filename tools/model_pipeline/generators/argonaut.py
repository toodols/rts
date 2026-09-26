"""unit_defs/ship_t1.luau `argonaut` (BAR legnavyfrigate, Legion's Argonaut): a frigate with a deck torpedo launcher.

A broad, short frigate: a full-bodied hull, wide well forward and rounding in to a raked bow, with a stepped,
team-coloured superstructure over its after half, its bridge windows glowing amber and a mast on its roof carrying
BAR's spinning fan. On the foredeck ahead of it is the torpedo turret (weapon 1): a low six-sided team-coloured
gun house carrying a dark launcher box of torpedo tubes, pitched a little up, their mouths glowing. Built to the
100-triangle limit (shared/ship_t1.py).
"""

import math

from .shared import common
from .shared import palette
from .shared import ship_t1 as ship

CATEGORY = "ship"
DEF = "argonaut"
MOUNTS = {
    1: {"pivot": (0, 0.7712, 1.2168), "muzzle": (-0.3422, 0.374, 0.5288)},
}


def generate(params):
    accent = params["color"]
    hull = ship.Hull(5.2, 2.2, 0.5, [(0.0, 0.8), (0.2, 1.0), (0.6, 0.94), (0.85, 0.6), (1.0, 0.0)],
                     sheer=0.26, flare=0.78, rake=0.1, stern_rake=0.04)

    # The superstructure over the after half: a low gunmetal deck house, part of the hull's mesh, and on it a
    # narrower team-coloured bridge, set back, both with their fronts sloping back.
    sy = 0.95
    base_z = hull.deck_at(sy) - 0.02
    house = ship.block("house", 1.3, 1.8, 0.3, 1.14, 1.64, off=(0.0, 0.08), origin=(0.0, sy, base_z))
    objects = [common.body_mat(common.merge("hull", [hull.build(), house]))]
    z2 = base_z + 0.3
    by = sy + 0.2
    objects.append(common.accent_mat(ship.block("bridge", 0.9, 1.0, 0.36, 0.72, 0.8, off=(0.0, 0.08), origin=(0.0, by, z2)), accent))
    # the bridge's front face runs from y = by - 0.5 at its foot to by - 0.32 at its top, 0.36 higher: half a stud
    # back for each stud up
    objects.append(common.glow_mat(ship.front_window("windows", 0.64, 0.1, by - 0.5 + 0.15 * 0.5 - 0.008, z2 + 0.15, lean=0.05), palette.AMBER))

    # The mast on the bridge roof, and on it the fan, spinning flat (BAR's script spins its `fan` about the up axis).
    top = z2 + 0.36
    my = by + 0.15
    mast = ship.spire("mast", 0.14, 0.14, 0.62, origin=(0.0, my, top - 0.02))
    objects.append(common.trim_mat(common.merge("deck", [hull.build_deck(), mast])))
    fan = common.trim_mat(ship.block("fan", 0.7, 0.12, 0.05, 0.62, 0.06, origin=(0.0, my, top + 0.4)))
    objects.append(common.art_group(fan, "fan", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=5.2))

    # The torpedo turret on the foredeck: a low six-sided gun house (accent) and on it the launcher box (trim),
    # pitched a little up, with the mouths of its tubes glowing at its front.
    ty = -1.2
    tz = hull.deck_at(ty)
    ring = [(0.36 * math.cos(a), 0.36 * math.sin(a)) for a in (math.pi * k / 3 for k in range(6))]
    top_ring = [(0.3 * x / 0.36, 0.3 * y / 0.36) for x, y in ring]
    house = common.accent_mat(ship.prism("turret_house", ring, 0.2, top_outline=top_ring), accent)
    w, h, length = 0.5, 0.22, 0.78
    box = ship.loft("turret_launcher", [
        [(-w / 2, length / 2, -h / 2), (w / 2, length / 2, -h / 2), (w / 2, length / 2, h / 2), (-w / 2, length / 2, h / 2)],
        [(-w / 2, -length / 2, -h / 2), (w / 2, -length / 2, -h / 2), (w / 2, -length / 2, h / 2), (-w / 2, -length / 2, h / 2)],
    ], cap_first=True, cap_last=True)
    pitch = math.radians(-8.0)
    box.rotation_euler = (pitch, 0.0, 0.0)
    box.location = (0.0, -0.12, 0.33)
    common.trim_mat(box)
    turret = common.merge("turret", [house, box], origin=(0.0, ty, tz))
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))
    # the tube mouths: a glowing panel just ahead of the launcher's front face, tilted with it
    fy = -0.12 - length / 2 - 0.004
    c, s = math.cos(pitch), math.sin(pitch)

    def tilt(x, y, z):
        # (x, y, z) with z from the box's middle, turned about that middle as its rotation_euler turns the box
        dy, dz = y - (-0.12), z
        return (x, ty + (-0.12) + dy * c - dz * s, tz + 0.33 + dy * s + dz * c)

    mw, mh = w * 0.8, h * 0.6
    mouths = ship.quad("turret_mouths", [tilt(-mw / 2, fy, -mh / 2), tilt(mw / 2, fy, -mh / 2), tilt(mw / 2, fy, mh / 2), tilt(-mw / 2, fy, mh / 2)])
    common.glow_mat(mouths, palette.AMBER)
    objects.append(common.art_group(mouths, "turret_1"))

    return objects
