"""unit_defs/t3.luau `vanguard` (BAR armvang): the all-terrain heavy plasma artillery walker.

Held to 100 triangles. Built as a
four-legged spider rather than a biped, so it cannot be mistaken for the Shiva or the Juggernaut: a squat
armoured hull on four high-kneed legs that come down to spiked feet (it climbs anything), carrying a
team-coloured turret with a long plasma cannon in a heavy cradle and a counterweight at the back.

The hull is the static base; each leg is its own kind="leg" piece sweeping about the vertical as it walks; the
turret, cradle and barrel are one piece following weapon 1's aim
(the def's weapon has no turret, so for now it simply stays facing forward).
"""

import math

from .shared import air_t1 as air
from .shared import common
from .shared import palette
from .shared import t3 as t3

CATEGORY = "entity"
DEF = "vanguard"
# its legs sweep about the vertical as it walks, carrying its splayed feet past the corners of its footprint
ENVELOPE = {"width": 6.24}
MOUNTS = {
    1: {"pivot": (0, 4.3237, -0.1067), "muzzle": (-0.1832, 0.6519, 3.0612)},
}
SWING = 0.25
# a foot sits about 1.5 studs out from its hip, so a sweep of +-SWING moves it 2 * 1.5 * sin(SWING) each way
STRIDE = round(4.0 * 1.5 * math.sin(SWING), 2)


def generate(params):
    accent = params["color"]
    m = common.Materials(accent, palette.HEAT_ORANGE)
    objects = []

    hull_z = 2.0
    hull = common.drop_bottom(common.block("hull", 2.2, 2.8, 1.25, top=(1.8, 2.3), origin=(0.0, 0.0, hull_z)))
    m.body(hull)
    objects.append(hull)

    # Four legs on the diagonals: a thigh rising out to a high knee, then a shin spiking down to the ground.
    # Each leg is its own walking piece sweeping fore and aft about a vertical axis through its root on the
    # hull; diagonal pairs share a phase. The model faces -Y, so its left is +X: front-left (+X, -Y) and
    # back-right (-X, +Y) step together, then front-right and back-left.
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            hip = (sx * 0.75, sy * 0.95, hull_z + 0.55)
            knee = (sx * 1.8, sy * 1.5, hull_z + 1.45)
            foot = (sx * 1.95, sy * 1.75, 0.0)
            # triangular sections: the thigh with a flat on top, the shin with a corner facing out
            thigh = t3.tube(f"thigh_{sx:+.0f}{sy:+.0f}", hip, knee, 0.36, sides=3, radius2=0.40, open_start=True,
                            roll=3.14159)
            shin = t3.tube(f"shin_{sx:+.0f}{sy:+.0f}", (knee[0], knee[1], knee[2] + 0.2), foot, 0.42, sides=3,
                           radius2=0.0, up=(sx, sy, 0.0))
            front = "front" if sy < 0 else "back"
            left = "left" if sx > 0 else "right"
            phase = 0.0 if (sx > 0) == (sy < 0) else 0.5
            objects.append(t3.leg_piece(f"leg_{front}_{left}", [thigh, shin], hip, m.trim, f"leg_{front}_{left}",
                                        axis=(0.0, 0.0, 1.0), swing=SWING, phase=phase, stride=STRIDE))

    # Turret, built about its swivel point on the hull roof.
    pivot = (0.0, 0.1, hull_z + 1.25)
    px, py, pz = pivot
    turret = common.drop_bottom(common.block("turret", 1.6, 1.9, 0.85, top=(1.2, 1.5), top_offset=(0.0, 0.1), origin=pivot))
    m.accent(turret)
    counterweight = common.block("counterweight", 1.3, 0.9, 0.7, top=(1.1, 0.8), origin=(px, py + 1.25, pz + 0.05))
    common.drop_faces(counterweight, [0])
    m.accent(counterweight)
    # heavy cradle out of the turret face, and the long barrel out of the cradle, raised a little
    cradle = air.beam("cradle", (px, py - 0.4, pz + 0.45), (px, py - 1.35, pz + 0.5), 0.75, 0.62, top_scale=0.85,
                      open_start=True)
    barrel = air.beam("barrel", (px, py - 1.2, pz + 0.5), (px, py - 2.85, pz + 0.62), 0.36, 0.36, open_start=True)
    for obj in (cradle, barrel):
        common.drop_facing(obj, (0, 0, -1), threshold=0.7)
        m.trim(obj)
    muzzle = air.plate("muzzle", (px, py - 2.86, pz + 0.62), (0.13, 0, 0), (0, 0.01, 0.13), (0, -1, 0))
    m.glow(muzzle, palette.PLASMA_BLUE)
    for obj in (turret, counterweight, cradle, barrel, muzzle):
        objects.append(common.art_group(obj, "turret"))
    common.art_group(turret, "turret", pivot=True, kind="turret", weapon=1)

    return objects
