"""unit_defs `tidal_generator` (cortide): 1 cell wide and long (4x4 studs), 26/11 studs tall, tide-blue accent.
It floats: its origin is the water's surface. Budget: 100 triangles.

A floating tide mill: two dark pontoon hulls riding the surface side by side, a team-coloured generator
house bridging them at the back with a glowing intake panel on its face, a dark beam tying the bows together,
and between the hulls a gunmetal six-paddle wheel that dips into the water and turns about its axle (Blender X), its own
rigid piece (common.art_group, kind="spin") pivoting on the axle's centre.
"""

import math

from . import common
from . import economy_common as eco


def generate(params):
    w = float(params.get("width", 4.0))
    height = float(params.get("height", 26.0 / 11.0))
    s = w / 4.0
    objects = []

    px = 1.42 * s
    deck_z = 0.45 * s
    hulls = eco.Mesh()
    for sx in (-1.0, 1.0):
        # sloped hull sides, narrowing below the waterline; the underside is never seen
        hulls.frustum(eco.rect(0.75 * s, 3.4 * s, (sx * px, 0.1 * s)), eco.rect(1.1 * s, 3.95 * s, (sx * px, 0.0)), -0.4 * s, deck_z)
    objects.append(eco.trim(hulls.build("hulls")))

    house_z1 = height * 0.72
    house = eco.Mesh().frustum(eco.rect(2.4 * s, 1.2 * s, (0.0, 1.35 * s)), eco.rect(1.9 * s, 0.9 * s, (0.0, 1.45 * s)), deck_z - 0.05 * s, house_z1)
    # a vent cowl on the roof
    house.frustum(eco.rect(0.9 * s, 0.6 * s, (0.35 * s, 1.5 * s)), eco.rect(0.7 * s, 0.45 * s, (0.35 * s, 1.55 * s)), house_z1, house_z1 + 0.35 * s)
    objects.append(eco.accent(house.build("generator_house"), "tide", eco.TIDE))

    # glowing intake on the house's front face, which leans back by the frustum's slope
    fy0, fy1 = 1.35 * s - 0.6 * s, 1.45 * s - 0.45 * s
    z0, z1 = deck_z - 0.05 * s, house_z1
    def face_y(z):
        return fy0 + (fy1 - fy0) * (z - z0) / (z1 - z0) - 0.01 * s
    za, zb, hw = z0 + 0.25 * s, z1 - 0.2 * s, 0.6 * s
    intake = eco.Mesh().poly([(-hw, face_y(za), za), (hw, face_y(za), za), (hw * 0.9, face_y(zb), zb), (-hw * 0.9, face_y(zb), zb)])
    objects.append(eco.glow(intake.build("intake"), "tide", eco.TIDE_GLOW, emission=1.0))

    dark = eco.Mesh()
    # bow beam tying the hulls together, and a mast with a light on the house
    dark.frustum(eco.rect(3.9 * s, 0.3 * s, (0.0, -1.83 * s)), eco.rect(3.9 * s, 0.22 * s, (0.0, -1.83 * s)), deck_z - 0.05 * s, deck_z + 0.25 * s)
    dark.pyramid(eco.at(eco.rect(0.2 * s, 0.2 * s, (-0.6 * s, 1.5 * s)), house_z1), (-0.6 * s, 1.5 * s, height + 0.1 * s))
    objects.append(eco.trim(dark.build("beams")))

    # The paddle wheel between the hulls, turning about its axle.
    ax_y, ax_z = -0.55 * s, 0.35 * s
    wheel = eco.Mesh()
    half = 0.85 * s
    for k in range(3):
        # three boards crossed through the axle make six paddles
        m = eco.matrix((0.0, ax_y, ax_z), (math.radians(90.0 + 60.0 * k), 0.0, 0.0))
        board = eco.rect(2 * half, 0.16 * s)
        wheel.frustum(board, board, -1.1 * s, 1.1 * s, m=m, cap_bottom=True)
    # the axle: a square bar along X whose ends vanish into the hulls
    m = eco.matrix((0.0, ax_y, ax_z), (0.0, math.pi / 2.0, 0.0))
    axle = eco.rect(0.32 * s, 0.32 * s)
    wheel.frustum(axle, axle, -px, px, m=m, cap_top=False)
    paddles = eco.body(wheel.build("paddle_wheel", location=(0.0, ax_y, ax_z)))
    objects.append(common.art_group(paddles, "wheel", pivot=True, kind="spin", axis=(1.0, 0.0, 0.0), speed=1.3))

    return objects
