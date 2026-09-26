"""unit_defs/defense.luau `prevailer` (BAR's corfmd): an anti-nuke interceptor, held to
100 triangles. A sloped footing carries a tall six-sided launch tower braced by four leaning fins, with glowing
strips up its faces; a team-coloured collar flares out under the launch hatch, a hexagonal lid hinged at the back,
and a tracking radar on a mast behind it sweeps the sky for incoming missiles.

The lid is its own piece ("hatch"), kind "hatch": it lifts LID_OPEN radians about its back edge (the hinge line runs
along X) each time weapon 1 fires, then closes. The radar plate is piece "radar", spinning about the vertical.
"""

import math

from .shared import common
from .shared import defense_b as d
from .shared import palette

CATEGORY = "entity"
DEF = "prevailer"
RADAR_SPEED = 1.6  # radians a second
LID_OPEN = 1.4  # radians the lid lifts when an interceptor launches


def generate(params):
    w, l = params["collider"]["width"], params["collider"]["length"]
    accent = params["color"]
    objects = []

    base_h = 1.6
    objects.append(common.trim_mat(d.block("footing", w, l, base_h, top=(7.0, 7.0))))

    # the launch tower: a hexagon with a flat to the front, narrowing as it rises
    r0, r1 = 2.9, 2.3
    tower_top = 8.2
    h = tower_top - base_h
    objects.append(common.body_mat(d.prism("tower", r0, h, 6, radius2=r1, origin=(0.0, 0.0, base_h), cap_top=False)))

    # glowing strips up the faces (a face's normal looks out at 270 + 60k degrees)
    lean = (r0 - r1) * math.cos(math.radians(30.0)) / h
    fm = (r0 + r1) / 2.0 * math.cos(math.radians(30.0)) + 0.03
    for a_deg in (270.0, 210.0, 330.0, 90.0):
        a = math.radians(a_deg)
        n = (math.cos(a), math.sin(a))
        along = (-n[1] * 0.16, n[0] * 0.16, 0.0)
        up = (-n[0] * lean * h * 0.36, -n[1] * lean * h * 0.36, h * 0.36)
        objects.append(common.glow_mat(d.panel("strip", (n[0] * fm, n[1] * fm, base_h + h * 0.45), along, up), palette.INTERCEPTOR_BLUE))

    # fins leaning against the tower on the diagonals
    for i in range(4):
        a = math.radians(45.0 + 90.0 * i)
        c = (math.cos(a) * 3.0, math.sin(a) * 3.0, base_h)
        objects.append(common.trim_mat(common.pyramid("fin", 1.3, 1.3, 4.6, apex=(-math.cos(a) * 0.9, -math.sin(a) * 0.9), origin=c, base=False)))

    # the collar flaring out under the lid, in the team colour
    collar_h = 0.9
    objects.append(common.accent_mat(d.prism("collar", r1, collar_h, 6, radius2=r1 + 0.55, origin=(0.0, 0.0, tower_top),
                                  cap_top=False), accent))
    lid_z = tower_top + collar_h

    # radar mast behind the lid
    mast_top = 11.0
    mast_y = r1 + 1.2  # far enough back that the lid clears it as it lifts
    objects.append(common.body_mat(d.block("mast", 0.7, 0.7, mast_top - lid_z + 0.2, origin=(0.0, mast_y, lid_z - 0.2),
                                  top=(0.4, 0.4))))

    # the launch deck just under the lid, seen when it opens
    objects.append(common.trim_mat(d.disc("launch_deck", r1 + 0.5, 6, origin=(0.0, 0.0, lid_z - 0.08))))

    # the lid: a shallow hexagonal cap, hinged on its back edge
    rl = r1 + 0.5
    lid = common.accent_mat(d.prism("hatch", rl, 0.5, 6, radius2=rl * 0.75, origin=(0.0, 0.0, lid_z)), accent)
    s = rl * math.cos(math.radians(30.0))
    door = d.merged("hatch", [lid], origin=(0.0, s, lid_z))
    # right-hand rule about +X: negative lifts the front of a lid hinged at the back
    objects.append(common.art_group(door, "hatch", pivot=True, kind="hatch", weapon=1, axis=(1.0, 0.0, 0.0),
                                    open=-LID_OPEN))

    # the tracking radar: a flat plate on the mast's top, tipped back to look at the sky
    pivot = (0.0, mast_y, mast_top)
    plate = common.body_mat(d.block("radar", 2.8, 0.25, 1.4, origin=(0.0, mast_y, mast_top - 0.5)))
    d.bake([plate], d.rotate_about(pivot, "X", -25.0))
    radar = d.merged("radar", [plate], origin=pivot)
    objects.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=RADAR_SPEED))

    return objects
