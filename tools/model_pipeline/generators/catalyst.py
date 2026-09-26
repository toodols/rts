"""unit_defs/defense.luau `catalyst` (BAR's cortron): a tactical missile launcher, held
to 100 triangles. A sloped bunker carries a six-sided launch drum holding the missile upright, its top closed by
two team-coloured half-hexagon doors that split down the middle; a reload missile stands in a ready rack against
each side, and amber warning strips light the drum's front faces.

Each door is its own piece ("hatch_1" on the -X side, "hatch_2" on +X), kind "hatch": it swings DOOR_OPEN radians up
and out about its outer hinge (the hinge line runs along Y) each time weapon 1 fires, then closes.
"""

import math

from .shared import common
from .shared import defense_b as d
from .shared import palette

CATEGORY = "entity"
DEF = "catalyst"
DOOR_OPEN = 1.3  # radians each door swings when a missile launches


def generate(params):
    w, l = params["collider"]["width"], params["collider"]["length"]
    accent = params["color"]
    objects = []

    objects.append(common.trim_mat(d.block("bunker", w, l, 1.9, top=(7.0, 7.0))))
    deck = 1.9

    # the launch drum: a hexagon with corners on +-X, so its doors split along Y; slightly narrower at the top
    r0, r1, hz = 3.0, 2.7, 3.2
    top_z = deck + hz
    objects.append(common.body_mat(d.prism("drum", r0, hz, 6, radius2=r1, origin=(0.0, 0.0, deck), cap_top=False,
                                  phase=0.0)))

    # a tall glowing seam up the middle of each front diagonal face (a face centred on angle a runs between
    # corners a - 30 and a + 30)
    z = deck + hz * 0.62
    r = r0 + (r1 - r0) * (z - deck) / hz
    lean = (r0 - r1) / hz
    for a_deg in (210.0, 330.0):
        c0 = (math.cos(math.radians(a_deg - 30.0)), math.sin(math.radians(a_deg - 30.0)))
        c1 = (math.cos(math.radians(a_deg + 30.0)), math.sin(math.radians(a_deg + 30.0)))
        n = (math.cos(math.radians(a_deg)), math.sin(math.radians(a_deg)))
        mid = ((c0[0] + c1[0]) / 2.0 * r + n[0] * 0.03, (c0[1] + c1[1]) / 2.0 * r + n[1] * 0.03, z)
        along = ((c1[0] - c0[0]) * r * 0.06, (c1[1] - c0[1]) * r * 0.06, 0.0)
        up = (-n[0] * lean * 0.85, -n[1] * lean * 0.85, 0.85)
        objects.append(common.glow_mat(d.panel("warning", mid, along, up), palette.WARNING_AMBER))

    # ready racks: a reload missile standing against each side
    for sx in (-1.0, 1.0):
        base = (sx * (r0 + 0.35), 0.0, deck)
        missile = common.body_mat(d.prism("missile", 0.62, 3.8, 6, origin=base, cap_top=False))
        nose = common.accent_mat(d.cone("nose", 0.62, 1.5, 6, origin=(base[0], base[1], deck + 3.8)), accent)
        # leaning in against the drum
        d.bake([missile, nose], d.rotate_about(base, "Y", -sx * 3.0))
        objects += [missile, nose]

    # an exhaust deflector ramp at the front of the drum
    objects.append(common.trim_mat(d.block("deflector", 3.0, 1.6, 1.0, origin=(0.0, -(r0 * 0.866 + 0.6), deck), top=(2.6, 0.2),
                                  top_offset=(0.0, 0.65), cap_top=False)))

    # the launch deck just under the doors, seen when they open
    objects.append(common.trim_mat(d.disc("launch_deck", r1 - 0.01, 6, origin=(0.0, 0.0, top_z - 0.15), phase=0.0)))

    # the doors: each half of the hexagonal top, flat-sided slabs hinged along the top of their outer corner, so
    # they lift up and out (right-hand rule about +Y: the +X door opens positive, the -X door negative) and stand
    # clear inside the reload missiles instead of swinging into them
    thick = 0.45
    s = r1 * math.sin(math.radians(60.0))
    for i, side in enumerate((-1.0, 1.0), start=1):
        g = 0.04
        if side > 0:
            pts = [(g, -s), (r1 * 0.5, -s), (r1, 0.0), (r1 * 0.5, s), (g, s)]
        else:
            pts = [(-g, s), (-r1 * 0.5, s), (-r1, 0.0), (-r1 * 0.5, -s), (-g, -s)]
        leaf = common.accent_mat(d.extrude(f"hatch_{i}", pts, thick, origin=(0.0, 0.0, top_z)), accent)
        hinge = (side * r1, 0.0, top_z + thick)
        door = d.merged(f"hatch_{i}", [leaf], origin=hinge)
        objects.append(common.art_group(door, f"hatch_{i}", pivot=True, kind="hatch", weapon=1, axis=(0.0, 1.0, 0.0),
                                        open=side * DOOR_OPEN))

    return objects
