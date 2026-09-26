"""unit_defs/t3.luau `shiva` (BAR corshiva): the amphibious siege mech.

Held to 100 triangles. A
reverse-jointed "chicken walker", unlike the Juggernaut's upright columns or the Vanguard's four legs: a wedge of
a team-coloured hull carried high on two backward-bending legs with clawed wedge feet, a glowing cockpit slit, a
heavy plasma cannon slung along its right flank, a rocket box on its left and a tall snorkel intake on its back
for wading along the sea floor.

Each leg (thigh, shin and foot, reverse knee included) is one kind="leg" piece swinging fore and aft about its
hip while it walks; the hull and its guns are one piece following weapon 1's aim (the def's
weapons have no turret, so for now it simply stays facing forward).
"""

import math

from .shared import air_t1 as air
from .shared import common
from .shared import palette
from .shared import t3 as t3

CATEGORY = "entity"
DEF = "shiva"
MOUNTS = {
    1: {"pivot": (0, 3.4286, 0), "muzzle": (1.3745, 0.7481, 2.7727)},
}
HIP_Z = 3.6
SWING = 0.25
STRIDE = round(4.0 * HIP_Z * math.sin(SWING), 2)


def generate(params):
    accent = params["color"]
    m = common.Materials(accent, palette.HEAT_ORANGE)
    hull_z = 3.3
    upper = []

    hull = common.drop_bottom(common.block("hull", 2.0, 2.7, 1.15, top=(1.5, 1.9), top_offset=(0.0, 0.3), origin=(0.0, 0.0, hull_z)))
    m.accent(hull)
    upper.append(hull)
    # cockpit slit across the sloped nose
    slit = air.plate("cockpit", (0.0, -1.24, hull_z + 0.62), (0.5, 0, 0), (0, 0.06, 0.1), (0, -0.9, 0.45))
    m.glow(slit)
    upper.append(slit)
    # snorkel stack at the back
    snorkel = common.block("snorkel", 0.5, 0.6, 1.0, top=(0.36, 0.46), top_offset=(0.0, 0.12), origin=(-0.45, 1.0, hull_z + 0.95))
    common.drop_faces(snorkel, [0])
    m.accent(snorkel)
    upper.append(snorkel)

    # Plasma cannon along the right flank.
    cannon = air.beam("cannon", (1.12, 0.7, hull_z + 0.8), (1.12, -2.3, hull_z + 0.85), 0.5, 0.46, top_scale=0.65,
                      open_start=True)
    common.drop_facing(cannon, (0, 0, -1), threshold=0.7)
    m.trim(cannon)
    upper.append(cannon)
    muzzle = air.plate("muzzle", (1.12, -2.31, hull_z + 0.85), (0.14, 0, 0), (0, 0, 0.13), (0, -1, 0))
    m.glow(muzzle)
    upper.append(muzzle)
    # Rocket box on the left flank, its tube face glowing.
    rockets = common.block("rockets", 0.85, 1.4, 0.95, top=(0.75, 1.2), origin=(-1.3, -0.05, hull_z + 0.2))
    common.drop_faces(rockets, [0])
    m.trim(rockets)
    upper.append(rockets)
    tubes = air.plate("tubes", (-1.3, -0.765, hull_z + 0.68), (0.3, 0, 0), (0, 0, 0.3), (0, -1, 0))
    m.glow(tubes)
    upper.append(tubes)

    for obj in upper:
        common.art_group(obj, "torso")
    common.art_group(hull, "torso", pivot=True, kind="turret", weapon=1)
    objects = list(upper)

    # Reverse-jointed legs: thigh down and forward to the knee, shin down and back to the ankle, wedge foot.
    # Each leg is one rigid walking piece swinging fore and aft about its hip.
    for side, group, phase in ((1.0, "leg_l", 0.0), (-1.0, "leg_r", 0.5)):
        x = side * 0.8
        hip = (x, 0.2, HIP_Z)
        knee = (side * 0.95, -0.75, 2.1)
        ankle = (side * 0.95, 0.55, 0.45)
        thigh = t3.tube(f"thigh_{side:+.0f}", hip, knee, 0.42, sides=3, radius2=0.36, open_start=True)
        shin = t3.tube(f"shin_{side:+.0f}", knee, ankle, 0.34, sides=3, radius2=0.26, open_start=True, open_end=True,
                       roll=3.14159)
        foot = t3.wedge(f"foot_{side:+.0f}", 0.95, 1.9, 0.55, 0.55, origin=(side * 0.95, 0.0, 0.0), ridge_x=0.6)
        objects.append(t3.leg_piece(f"leg_{side:+.0f}", [thigh, shin, foot], hip, m.trim, group,
                                    axis=(1.0, 0.0, 0.0), swing=SWING, phase=phase, stride=STRIDE))

    return objects
