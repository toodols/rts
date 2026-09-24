"""The rarest of the pool skin's floats (src/shared/skins/pool.luau): a rubber ducky ring. A yellow ring with a duck's
head rising from its front, orange beak forward, two dark eyes, and a little tail flicking up at the back, so the duck
faces the way the unit does (Blender -Y). See pool_float_common for how the ring is laid out.
"""

from . import common
from . import pool_float_common as ring

MAX_TRIANGLES = 280
RECENTRE = False

SEGMENTS = 12
SIDES = 6

YELLOW = (1.0, 0.83, 0.16, 1.0)
ORANGE = (1.0, 0.5, 0.08, 1.0)
EYE = (0.06, 0.06, 0.08, 1.0)

HEAD = 0.36
HEAD_Y = -ring.RING
HEAD_Z = ring.TUBE + HEAD * 0.75


def generate(params):
    body = ring.ring("ring", SEGMENTS, SIDES, lambda i, j: True)
    head = ring.ball("head", HEAD, (0.0, HEAD_Y, HEAD_Z))
    tail = ring.spike("tail", 0.26, 0.34, (0.0, 0.0, 1.0), (0.0, ring.RING, ring.TUBE * 0.8))
    # one material, so the export joins them into one mesh
    for part in (body, head, tail):
        common.apply_material(part, "rubber_ducky_yellow", YELLOW, roughness=0.3)

    beak = ring.spike("beak", HEAD * 0.7, HEAD * 0.9, (0.0, -1.0, 0.0), (0.0, HEAD_Y - HEAD * 0.8, HEAD_Z - HEAD * 0.15))
    common.apply_material(beak, "rubber_ducky_beak", ORANGE, roughness=0.3)

    eyes = [
        common.box("eye_l", 0.08, 0.05, 0.1, origin=(-HEAD * 0.45, HEAD_Y - HEAD * 0.78, HEAD_Z + HEAD * 0.2)),
        common.box("eye_r", 0.08, 0.05, 0.1, origin=(HEAD * 0.45, HEAD_Y - HEAD * 0.78, HEAD_Z + HEAD * 0.2)),
    ]
    for eye in eyes:
        common.apply_material(eye, "rubber_ducky_eyes", EYE, roughness=0.2)
    return [body, head, tail, beak] + eyes
