"""HUD icon: the Resurrect order, an ankh. Written to src/shared/ui_art/ (see shared/icon)."""

import math

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"

LOOP_Y, LOOP_RX, LOOP_RY = 0.8, 0.78, 1.05
ARM_TOP, ARM_BOTTOM, ARM_X = 0.45, -0.05, 1.45
FOOT_Y, NECK_X, FOOT_X = -1.95, 0.22, 0.42


def outline():
    # the right half, top to bottom: down the loop to where it meets the arm, round the arm, down the flaring stem
    meet = math.degrees(math.asin((ARM_TOP - LOOP_Y) / LOOP_RY))
    loop = [(LOOP_RX * math.cos(math.radians(a)), LOOP_Y + LOOP_RY * math.sin(math.radians(a))) for a in _steps(90.0, meet, 10)]
    neck = NECK_X + (FOOT_X - NECK_X) * (ARM_TOP - ARM_BOTTOM) / (ARM_TOP - FOOT_Y)
    return ic.mirrored(loop + [(ARM_X, ARM_TOP), (ARM_X, ARM_BOTTOM), (neck, ARM_BOTTOM), (FOOT_X, FOOT_Y), (0.0, FOOT_Y)])


def _steps(a0, a1, n):
    return [a0 + (a1 - a0) * i / n for i in range(n + 1)]


def generate(params):
    eye = [(0.38 * x, 1.1 + 0.5 * y) for x, y in ic.circle_points(0.0, 0.0, 1.0, 24)]
    return ic.build("resurrect", [ic.layer([ic.poly(outline(), [eye])], palette.ICON_FILL)])
