"""unit_defs/defense.luau `pulsar` (BAR's cordoom, the Tachyon Accelerator): a 2x3x2 cell (8 x 12 x 8 stud) heavy
beam tower, held to 100 triangles. A sloped square bastion with team-coloured capacitor spikes on its corners
carries a diamond-turned core column with glowing tachyon conduits on its faces; on it swivels a heavy armoured
head whose long accelerator barrel is ringed by two glowing coils and ends in a glowing tip.

The head is three objects (accent armour, dark barrel, glowing coils) in piece "turret_1", pivoting on the
column's axis, and follows weapon 1's aim.
"""

import math

from . import common
from . import defense_b_common as d

KEY = "pulsar"
GLOW = (0.2, 0.8, 1.0, 1.0)  # tachyon cyan


def accent(o):
    return d.accent(o, KEY, d.RUST)


def glow(o):
    return d.glow(o, KEY, GLOW, 1.0)


def _head(swivel):
    sx, sy, sz = swivel
    housing = accent(d.block("housing", 5.0, 5.2, 2.7, origin=(sx, sy + 0.4, sz), top=(3.8, 3.0), top_offset=(0.0, 0.6)))

    bz = sz + 1.25
    breech = (sx, sy - 1.6, bz)
    barrel = d.trim(d.prism("barrel", 0.55, 7.6, 6, origin=breech, cap_top=False))
    d.forward([barrel], breech)
    lit = []
    for y in (-3.3, -5.6):
        at = (sx, sy + y, bz)
        coil = d.block("coil", 1.35, 1.35, 0.7, origin=at, cap_bottom=True)
        coil.rotation_euler = (0.0, 0.0, math.radians(45.0))
        lit.append(d.forward([coil], at)[0])
    at = (sx, sy - 9.2, bz)
    lit.append(d.forward([d.pyramid("tip", 1.0, 1.0, 0.9, origin=at)], at)[0])
    for o in lit:
        glow(o)

    head = d.merged("head", [housing], origin=swivel)
    dark = d.merged("head_dark", [barrel], origin=swivel)
    shine = d.merged("head_glow", lit, origin=swivel)
    common.art_group(head, "turret_1", pivot=True, kind="turret", weapon=1)
    common.art_group(dark, "turret_1")
    common.art_group(shine, "turret_1")
    return [head, dark, shine]


def generate(params):
    objects = []

    objects.append(d.body(d.block("bastion", 8.0, 8.0, 2.8, top=(6.0, 6.0))))

    # the core: a square frustum turned 45 degrees, so its faces look out along the diagonals
    bottom, top = 2.8, 7.8
    r0, r1 = 2.3, 1.7  # its faces' distance from the axis, at the bottom and the top
    core = d.block("core", r0 * 2.0, r0 * 2.0, top - bottom, origin=(0.0, 0.0, bottom), top=(r1 * 2.0, r1 * 2.0),
                   cap_top=False)
    core.rotation_euler = (0.0, 0.0, math.radians(45.0))
    objects.append(d.body(core))

    # a glowing conduit up each of the core's faces
    h = top - bottom
    slant = math.hypot(h, r0 - r1)
    for i in range(4):
        a = math.radians(45.0 + 90.0 * i)
        out = (math.cos(a), math.sin(a))
        mid_r = (r0 + r1) / 2.0 + 0.03
        along = (-out[1] * 0.22, out[0] * 0.22, 0.0)
        up = (-out[0] * (r0 - r1) / slant * slant * 0.4, -out[1] * (r0 - r1) / slant * slant * 0.4, h * 0.4)
        strip = d.panel("conduit", (out[0] * mid_r, out[1] * mid_r, bottom + h * 0.5), along, up)
        objects.append(glow(strip))

    # capacitor spikes on the bastion's corners, in the team colour, leaning in toward the core
    for cx in (-1.0, 1.0):
        for cy in (-1.0, 1.0):
            spike = d.pyramid("spike", 1.5, 1.5, 4.4, origin=(cx * 2.7, cy * 2.7, 2.1), apex=(-cx * 0.4, -cy * 0.4))
            objects.append(accent(spike))

    objects.extend(_head((0.0, 0.0, top)))
    return objects
