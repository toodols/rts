"""unit_defs/vehicle_t2.luau `starlight` (BAR's armmanni): Armada's mobile tachyon weapon.

A broad tracked hull carrying the tachyon gun up high: a diamond-turned pedestal (the Pulsar's core in little)
under a team-coloured housing, out of which runs the Pulsar's own accelerator barrel at a fraction of its size --
dark, ringed by two glowing coils, with a glowing tip (shared/tachyon) -- since the two fire the same weapon.
The housing, barrel and glowing coils are three objects in piece "turret_1", turning about the pedestal's axis
with weapon 1's aim.
"""

import math

from .shared import common
from .shared import defense_b as d
from .shared import palette
from .shared import tachyon as t
from .shared import vehicle_t2 as v

CATEGORY = "entity"
DEF = "starlight"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 3.6}
MOUNTS = {
    1: {"pivot": (0, 2.4508, 0.0267), "muzzle": (0, 0.346, 1.7727)},
}


def generate(params):
    m = common.Materials(params["color"], palette.HEADLIGHT)
    objects = []

    L, W = 2.6, 2.3  # hull footprint, fitted in the collider circle
    hl, hw = L / 2.0, W / 2.0
    deck_lo, deck_z = 0.45, 0.95
    glacis = 0.5

    # Footprint first: one broad deck riding on the tracks, a sloped glacis in front, a short slope behind (14 tris).
    deck = v.prism_x("deck", [(-hl + 0.05, deck_lo), (-hl + glacis, deck_z), (hl - 0.15, deck_z), (hl, 0.75),
                              (hl, deck_lo)], W)
    objects.append(m.body(deck))

    # The tracks under the deck's edges (8 tris each), and a team-colour stripe along the deck over each (2).
    for side in (-1, 1):
        objects.append(m.trim(v.track(f"track_{side}", side * (hw - 0.27), L + 0.1, 0.55, 0.5)))
        x = side * (hw - 0.24)
        sz = deck_z + 0.005
        stripe = v.decal(f"stripe_{side}", [(x - 0.12, -hl + glacis + 0.05, sz), (x + 0.12, -hl + glacis + 0.05, sz),
                                             (x + 0.12, hl - 0.2, sz), (x - 0.12, hl - 0.2, sz)])
        objects.append(m.accent(stripe))

    # Headlights on the glacis (2 tris each).
    gy0, gz0, gy1, gz1 = -hl + 0.05, deck_lo, -hl + glacis, deck_z
    for side in (-1, 1):
        a, b = 0.3, 0.6
        x0, x1 = side * 0.2, side * 0.5
        p0 = (gy0 + (gy1 - gy0) * a - 0.012, gz0 + (gz1 - gz0) * a + 0.009)
        p1 = (gy0 + (gy1 - gy0) * b - 0.012, gz0 + (gz1 - gz0) * b + 0.009)
        light = v.decal(f"headlight_{side}", [(x0, p0[0], p0[1]), (x1, p0[0], p0[1]), (x1, p1[0], p1[1]),
                                               (x0, p1[0], p1[1])], up=(0.0, -0.8, 0.6))
        objects.append(m.glow(light))

    # The pedestal: a square frustum turned 45 degrees, as the Pulsar's core, open top and bottom (8 tris).
    pivot_y = 0.0
    ped_top = 1.7
    r0, r1 = 0.475, 0.3  # its faces' distance from the axis, at the bottom and the top
    h = ped_top - deck_z
    pedestal = d.block("pedestal", r0 * 2.0, r0 * 2.0, h, origin=(0.0, pivot_y, deck_z), top=(r1 * 2.0, r1 * 2.0),
                       cap_top=False)
    pedestal.rotation_euler = (0.0, 0.0, math.radians(45.0))
    objects.append(m.body(pedestal))

    # A glowing tachyon conduit up each of its two front faces, as on the Pulsar's core (2 tris each).
    for deg in (225.0, 315.0):
        a = math.radians(deg)
        out = (math.cos(a), math.sin(a))
        mid_r = (r0 + r1) / 2.0 + 0.01
        along = (-out[1] * 0.07, out[0] * 0.07, 0.0)
        up = (-out[0] * (r0 - r1) * 0.4, -out[1] * (r0 - r1) * 0.4, h * 0.4)
        strip = d.panel("conduit", (out[0] * mid_r, pivot_y + out[1] * mid_r, deck_z + h * 0.5), along, up)
        objects.append(m.glow(strip, palette.TACHYON))

    # The housing, team-coloured, swivelling on the pedestal's axis (10 tris).
    swivel = (0.0, pivot_y, ped_top)
    housing = common.block("housing", 0.95, 1.0, 0.52, top=(0.72, 0.58), top_offset=(0.0, 0.11), at=(0.0, pivot_y + 0.08, ped_top), drop=('bottom',))
    m.accent(housing)

    # The Pulsar's accelerator barrel at 0.16 of its size, its breech buried in the housing (40 tris).
    breech = (0.0, pivot_y - 0.3, ped_top + 0.24)
    barrel, lit = t.barrel(breech, scale=0.16)

    head = d.merged("head", [housing], origin=swivel)
    dark = d.merged("head_dark", [barrel], origin=swivel)
    shine = d.merged("head_glow", lit, origin=swivel)
    objects.append(common.art_group(head, "turret_1", pivot=True, kind="turret", weapon=1))
    objects.append(common.art_group(dark, "turret_1"))
    objects.append(common.art_group(shine, "turret_1"))

    return objects
