"""unit_defs/defense.luau `apocalypse` (BAR's corsilo): a 3x2x3 cell (12 x 8 x 12 stud) nuclear missile silo, held to
100 triangles. A wide sloped platform holds a heavy octagonal silo collar, closed by two team-coloured
half-octagon blast doors that split down the middle and swing on heavy hinge housings along both sides; a vent
stack rises at the back, and glowing red warning strips light the collar's front.

Each blast door is its own piece ("hatch_1" on the -X side, "hatch_2" on +X), kind "hatch": it swings DOOR_OPEN
radians up about its outer hinge (the hinge line runs along Y) each time weapon 1 fires, then closes.
"""

import math

from . import common
from . import defense_b_common as d

KEY = "apocalypse"
LIGHT = (1.0, 0.25, 0.12, 1.0)  # warning red
DOOR_OPEN = 1.6  # radians each blast door swings when a missile launches


def accent(o):
    return d.accent(o, KEY, d.RUST)


def glow(o):
    return d.glow(o, KEY, LIGHT, 0.8)


def generate(params):
    objects = []

    deck = 2.0
    objects.append(d.trim(d.block("platform", 12.0, 12.0, deck, top=(10.6, 10.6))))

    # the silo collar: an octagon (flats on the axes) that the doors close
    r0, r1, hz = 4.4, 4.0, 2.6
    phase = math.radians(22.5)
    top_z = deck + hz
    objects.append(d.body(d.prism("collar", r0, hz, 8, radius2=r1, origin=(0.0, 0.0, deck), cap_top=False,
                                  phase=phase)))
    f0 = r0 * math.cos(math.radians(22.5))
    f1 = r1 * math.cos(math.radians(22.5))

    # heavy hinge housings along both sides, a little taller than the closed doors
    for sx in (-1.0, 1.0):
        objects.append(d.trim(d.block("hinge", 1.6, 6.6, hz + 0.9, origin=(sx * (f0 + 0.45), 0.0, deck),
                                      top=(0.9, 5.4), top_offset=(-sx * 0.25, 0.0))))

    # a vent stack at the back
    objects.append(d.body(d.block("stack", 2.6, 1.4, 4.4, origin=(0.0, 4.6, deck), top=(1.8, 0.9), top_offset=(0.0, 0.2))))

    # warning lights: a glowing strip on the collar's front flat and its front diagonals
    z = deck + hz * 0.5
    lean = (r0 - r1) * math.cos(math.radians(22.5)) / hz
    fm = (f0 + f1) / 2.0 + 0.03
    for a_deg in (270.0, 225.0, 315.0):
        a = math.radians(a_deg)
        n = (math.cos(a), math.sin(a))
        along = (-n[1] * 0.9, n[0] * 0.9, 0.0)
        up = (-n[0] * lean * 0.2, -n[1] * lean * 0.2, 0.2)
        objects.append(glow(d.panel("warning", (n[0] * fm, n[1] * fm, z), along, up)))

    # the silo floor just under the doors, seen when they open
    objects.append(d.trim(d.disc("silo_floor", r1 - 0.01, 8, origin=(0.0, 0.0, top_z - 0.15), phase=phase)))

    # the blast doors: each half of the octagonal top, flat-sided slabs hinged along the top of their outer flat, so
    # they stand up inside the hinge housings when open instead of swinging into them (right-hand rule about +Y:
    # the +X door opens positive, the -X door negative)
    thick = 0.55
    f = f1
    h = r1 * math.sin(math.radians(22.5))  # half a flat
    g = 0.05
    for i, side in enumerate((-1.0, 1.0), start=1):
        if side > 0:
            pts = [(g, -f), (h, -f), (f, -h), (f, h), (h, f), (g, f)]
        else:
            pts = [(-g, f), (-h, f), (-f, h), (-f, -h), (-h, -f), (-g, -f)]
        leaf = accent(d.extrude(f"hatch_{i}", pts, thick, origin=(0.0, 0.0, top_z)))
        door = d.merged(f"hatch_{i}", [leaf], origin=(side * f, 0.0, top_z + thick))
        objects.append(common.art_group(door, f"hatch_{i}", pivot=True, kind="hatch", weapon=1, axis=(0.0, 1.0, 0.0),
                                        open=side * DOOR_OPEN))

    return objects
