"""unit_defs `thistle` (corrl): a light anti-air missile tower, 1x2x1 cells (4x8x4 studs). Under 100 triangles.

The tower line's sloped plinth and tapered column, topped by a missile yoke: a small armored cab between
two four-cell missile pods, pitched steeply up. The whole head yaws with weapon 1.
"""

from . import defense_a_common as d

KEY = "thistle"
SWIVEL_Z = 4.4
POD_ELEV = 42.0


def generate(params):
    base = d.Parts()
    # the tower line's sloped plinth and tapered column
    base.loft([d.square(3.9, 0.0), d.square(2.9, 1.1)], side="trim", top="trim")
    base.loft([d.square(1.4, 1.1), d.square(1.1, SWIVEL_Z)], side="body")

    head = d.Parts()
    fr = d.Frame()
    # the cab: a sloped glacis in front, a dark power block behind
    head.block_u(fr, 0.0, 0.05, 0.0, 1.2, (1.1, 1.6), (0.8, 1.0), top_shift_f=-0.2,
                 tags={"all": "accent", "bottom": None})
    head.block_u(fr, 0.0, -0.95, 0.1, 0.85, (0.8, 0.5), (0.7, 0.4), tags={"all": "trim", "bottom": None, "fore": None})
    for side in (-1.0, 1.0):
        pod = d.Frame(origin=(side * 0.84, 0.0, 0.95), elev=POD_ELEV)
        # a launcher box narrowing a little to its dark front face, four lit tube mouths on it
        head.block_f(pod, 0.0, 0.0, -0.95, 1.0, (0.72, 0.8), (0.62, 0.68), tags={"all": "accent", "front": "trim"})
        # a dark clamp band round the pod
        head.block_f(pod, 0.0, 0.0, -0.3, -0.1, (0.78, 0.86), tags={"all": "trim", "back": None, "front": None})
        for x in (-0.15, 0.15):
            for u in (-0.16, 0.16):
                head.quad_f(pod, x, 1.005, u, 0.17, 0.17)

    objects = d.base_objects(base, KEY, "trim")
    objects += d.head_objects(head, (0.0, 0.0, SWIVEL_Z), KEY)
    return objects
