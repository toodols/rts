"""unit_defs/bot_t1.luau `aggravator` (corstorm): Cortex's rocket bot.

A lean bot built around one big rocket launcher: a box of tubes slung over the right shoulder and
tilted up, its glowing rocket noses showing at the front, balanced by a sensor head and an armored
pad on the left and a counterweight pack on the back. The upper body turns as weapon 1's turret; each leg swings about its hip as it walks.

Budget: 100 triangles.
"""

import math

from .shared import bot_t1 as bt
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "aggravator"
MOUNTS = {
    1: {"pivot": (0, 0, 0), "muzzle": (0.4541, 2.194, 1)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent, palette.ROCKET_MOTOR)

    upper = []
    chest = m.body(bt.slab("chest", 0.44, 0.36, 0.54, top_w=0.66, top_d=0.48, origin=(0.0, 0.0, 1.14)))
    upper.append(chest)
    upper.append(m.body(bt.slab("head", 0.26, 0.3, 0.22, top_w=0.2, top_d=0.22, top_offset=(0.0, 0.03), origin=(-0.12, -0.12, 1.68))))
    upper.append(m.glow(bt.visor("visor", -0.12, -0.275, 1.79, 0.2, 0.06, lean=0.01)))
    upper.append(m.accent(bt.slab("pad_l", 0.26, 0.4, 0.2, top_w=0.18, top_d=0.3, top_offset=(-0.03, 0.0), origin=(-0.42, 0.0, 1.58))))
    upper.append(m.trim(bt.slab("pack", 0.4, 0.2, 0.42, top_w=0.36, top_d=0.16, origin=(0.0, 0.3, 1.24))))

    # the launcher: a long box over the right shoulder, pitched up 14 degrees, open tubes at the front
    lx, lz = 0.42, 1.86
    pitch = math.radians(14.0)
    back = (lx, 0.44, lz - 0.44 * math.sin(pitch))
    front = (lx, -0.66, lz + 0.66 * math.sin(pitch))
    launcher = m.accent(bt.beam("launcher", back, front, 0.34, 0.34, 0.36, 0.36, caps="b"))
    upper.append(launcher)
    # its open front: a dark face with two rows of glowing rocket noses set just in front of it
    face = [tuple(launcher.data.vertices[i].co) for i in range(4, 8)]
    upper.append(m.trim(bt.quad("launcher_face", face)))
    up = (0.0, math.sin(pitch), math.cos(pitch))  # along the face, toward its top
    fwd = (0.0, -math.cos(pitch) * 0.012, math.sin(pitch) * 0.012)
    fx, fy, fz = front
    for row in (-1.0, 1.0):
        c = (fx, fy + fwd[1] + up[1] * row * 0.085, fz + fwd[2] + up[2] * row * 0.085)
        corners = []
        for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
            corners.append((c[0] + sx * 0.13, c[1] + up[1] * sy * 0.05, c[2] + up[2] * sy * 0.05))
        upper.append(m.glow(bt.quad(f"rockets_{row}", corners)))

    # each leg is one rigid piece swinging about its hip while the unit walks, the two half a cycle apart
    legs = []
    for name, side, phase in (("leg_l", -1.0, 0.0), ("leg_r", 1.0, 0.5)):
        hip = (side * 0.24, 0.0, 1.18)
        parts = bt.leg(m, name, hip, (side * 0.28, -0.13, 0.66), (side * 0.28, 0.0), 0.24, 0.5, 0.22, 0.19)
        legs.append(bt.walking_leg(name, parts, hip, m.trim, phase, 0.38))

    bt.group(upper, "torso", chest, kind="turret", weapon=1)
    objs = upper + legs
    return objs
