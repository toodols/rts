"""unit_defs/defense.luau `calamity` (BAR's corbuzz): a rapid fire long range plasma
cannon, held to 100 triangles. A sloped square bunker climbs into a tall tower with glowing plasma feeds up its
faces, which flares out into a team-coloured gun deck; on it swivels a heavy gun house carrying a three-barrel
rotary cannon, raised toward the sky the way a long range gun sits, its muzzle clamp glowing.

The gun house is three objects (accent armour, dark cannon, glowing muzzle) in piece "turret_1", pivoting on the
tower's axis, and follows weapon 1's aim.
"""

import math

from .shared import common
from .shared import defense_b as d
from .shared import palette

CATEGORY = "entity"
DEF = "calamity"
MOUNTS = {
    1: {"pivot": (0, 10.5, 0), "muzzle": (-0.4114, 2.9238, 10.277)},
}
RISE = 14.0  # degrees the barrels are raised


def _head(swivel, accent):
    sx, sy, sz = swivel
    house = common.accent_mat(d.block("house", 5.2, 5.6, 2.7, origin=(sx, sy + 0.6, sz), top=(4.0, 3.4), top_offset=(0.0, 0.7)), accent)

    # the cannon, built standing up from its trunnion and then laid forward and raised
    tz = sz + 1.35
    trunnion = (sx, sy - 1.6, tz)
    cannon = []
    cannon.append(d.prism("drum", 1.3, 2.0, 6, origin=trunnion))
    barrel_len = 7.0
    for i in range(3):
        a = math.radians(90.0 + 120.0 * i)
        cannon.append(d.prism("barrel", 0.3, barrel_len, 4, origin=(sx + math.cos(a) * 0.72, trunnion[1] + math.sin(a) * 0.72,
                                                                   tz + 1.8), cap_top=False))
    clamp_z = tz + 1.8 + barrel_len - 1.3
    clamp = d.block("clamp", 2.2, 2.2, 0.9, origin=(sx, trunnion[1], clamp_z), cap_bottom=True)
    muzzle = d.panel("muzzle", (sx, trunnion[1], clamp_z + 0.92), (0.75, 0.0, 0.0), (0.0, 0.75, 0.0))
    d.forward(cannon + [clamp, muzzle], trunnion, rise=RISE)
    for o in cannon:
        common.trim_mat(o)
    common.accent_mat(clamp, accent)
    common.glow_mat(muzzle, palette.PLASMA_ORANGE)

    head = d.merged("head", [house, clamp], origin=swivel)
    dark = d.merged("head_dark", cannon, origin=swivel)
    shine = d.merged("head_glow", [muzzle], origin=swivel)
    common.art_group(head, "turret_1", pivot=True, kind="turret", weapon=1)
    common.art_group(dark, "turret_1")
    common.art_group(shine, "turret_1")
    return [head, dark, shine]


def generate(params):
    w, l = params["collider"]["width"], params["collider"]["length"]
    accent = params["color"]
    objects = []

    objects.append(common.body_mat(d.block("bunker", w, l, 3.0, top=(6.2, 6.2))))

    bottom, top = 3.0, 9.2
    r0, r1 = 2.7, 2.15  # half widths of the tower at its foot and top
    objects.append(common.body_mat(d.block("tower", r0 * 2.0, r0 * 2.0, top - bottom, origin=(0.0, 0.0, bottom),
                                  top=(r1 * 2.0, r1 * 2.0), cap_top=False)))

    # a glowing plasma feed up each face
    h = top - bottom
    for i in range(4):
        a = math.radians(90.0 * i)
        out = (math.cos(a), math.sin(a))
        mid_r = (r0 + r1) / 2.0 + 0.03
        along = (-out[1] * 0.2, out[0] * 0.2, 0.0)
        up = (-out[0] * (r0 - r1) * 0.42, -out[1] * (r0 - r1) * 0.42, h * 0.42)
        objects.append(common.glow_mat(d.panel("feed", (out[0] * mid_r, out[1] * mid_r, bottom + h * 0.46), along, up), palette.PLASMA_ORANGE))

    # the crown: the tower flares out into a wide gun deck
    objects.append(common.accent_mat(d.block("crown", r1 * 2.0, r1 * 2.0, 1.3, origin=(0.0, 0.0, top), top=(7.0, 7.0)), accent))

    objects.extend(_head((0.0, 0.0, top + 1.3), accent))
    return objects
