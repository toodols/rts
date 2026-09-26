"""unit_defs `commander`: the Cortex commander (corcom), under 100 triangles.

A broad armored humanoid: angular team-coloured pauldrons, a helmet with a glowing visor, a nanolathe emitter on
the left forearm and the D-gun on the right. Its legs walk (kind="leg", one rigid piece each from the hip), and the
torso turns toward whatever it is building (kind="work"), the legs staying with the body.

It is built at the size the hand-made rig it replaces was scaled up to (7.5 studs tall), which is how big BAR draws
its commander: well past its collider, which only decides how it is hit and
spaced. build.py's collision-volume fill only ever scales up, so it leaves it at this size.
"""

import math

from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "commander"
# it stands as tall as BAR draws it, well past its collider, which only decides how it is hit and spaced
ENVELOPE = {"width": 4.8, "length": 5.45, "height": 6.75}

HIP = 3.3  # height of the hips, where the legs swing
LEG_SWING = 0.35


def _leg(name, x, phase):
    """A thigh-to-ankle block and a foot, merged into one piece whose origin is the hip (20 triangles)."""
    shin = common.drop_bottom(common.block(f"{name}_shin", 0.8, 0.9, HIP - 0.35, top=(1.05, 1.15), origin=(0.0, 0.0, 0.35 - HIP)))
    foot = common.drop_bottom(
        common.block(f"{name}_foot", 1.1, 1.7, 0.45, top=(0.8, 0.9), top_offset=(0.0, 0.35), origin=(0.0, -0.2, -HIP))
    )
    for piece in (shin, foot):
        common.trim_mat(piece)
    leg = common.merge(name, [shin, foot], origin=(x, 0.0, HIP))
    # one step cycle covers about four times the hip height times the sine of the swing, so the feet keep pace
    stride = 4.0 * HIP * math.sin(LEG_SWING)
    return common.art_group(leg, name, pivot=True, kind="leg", axis=(1.0, 0.0, 0.0), swing=LEG_SWING, phase=phase, stride=stride)


def generate(params):
    objects = []

    # the torso comes first: it is what the model is centred on, and the pivot the upper body turns about
    torso = common.drop_bottom(common.block("torso", 2.0, 1.5, 2.5, top=(3.1, 2.0), top_offset=(0.0, 0.15), origin=(0.0, 0.0, HIP)))
    common.body_mat(torso)
    objects.append(common.art_group(torso, "upper", pivot=True, kind="work"))

    chest_top = HIP + 2.5
    helmet = common.drop_bottom(
        common.block("helmet", 1.15, 1.25, 0.95, top=(0.8, 0.85), top_offset=(0.0, 0.1), origin=(0.0, -0.1, chest_top))
    )
    common.accent_mat(helmet, params["color"])
    objects.append(common.art_group(helmet, "upper"))

    visor = common.pyramid("visor", 0.8, 0.25, 0.35, base=False)
    visor.rotation_euler = (math.radians(90.0), 0.0, 0.0)  # points out of the helmet's face
    visor.location = (0.0, -0.72, chest_top + 0.5)
    common.glow_mat(visor, palette.AQUA)
    objects.append(common.art_group(visor, "upper"))

    # angular pauldrons, four triangles each, leaning out over the shoulders
    for side in (-1.0, 1.0):
        pad = common.pyramid("pauldron", 1.3, 1.7, 1.1, apex=(side * 0.35, 0.0), origin=(side * 1.75, 0.1, chest_top - 0.55), base=False)
        common.accent_mat(pad, params["color"])
        objects.append(common.art_group(pad, "upper"))

    # forearms hanging forward from the shoulders: the D-gun on the right (-X, since it faces -Y), the nanolathe on
    # the left, each with a glowing tip
    for side, glow_name, color in ((-1.0, "dgun", palette.HOT_ORANGE), (1.0, "nano", palette.NANO)):
        arm, tip = common.strut(f"arm_{glow_name}", 0.75, 0.75, 2.3, (side * 1.8, -0.1, chest_top - 0.5), tilt_x=118.0)
        common.drop_bottom(arm)
        common.body_mat(arm)
        objects.append(common.art_group(arm, "upper"))
        glow = common.pyramid(f"{glow_name}_tip", 0.55, 0.55, 0.5, origin=tip, base=False)
        glow.rotation_euler = (math.radians(118.0), 0.0, 0.0)
        common.glow_mat(glow, color)
        objects.append(common.art_group(glow, "upper"))

    objects.append(_leg("leg_l", 0.75, 0.0))
    objects.append(_leg("leg_r", -0.75, 0.5))
    return objects
