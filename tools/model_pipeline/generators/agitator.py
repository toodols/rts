"""unit_defs `agitator` (corpun): plasma artillery, 2x2x2 cells (8x8x8 studs). Under 100 triangles.

The tower line's sloped plinth, broad and low, under a squat eight-sided armored dome with a bustle at the
back and one long gun lobbing forward and up out of a dark mantlet: a gunmetal barrel with a jacket at its
root and a heavy muzzle brake, the plasma glowing at its tip. The whole head yaws with weapon 1.
"""

from . import defense_a_common as d

KEY = "agitator"
SWIVEL_Z = 1.5
ELEV = 32.0


def generate(params):
    base = d.Parts()
    base.loft([d.square(7.8, 0.0), d.square(6.0, SWIVEL_Z)], side="trim", top="body")

    head = d.Parts()
    fr = d.Frame()
    head.loft([d.ngon(8, 2.8, 0.0), d.ngon(8, 1.95, 1.6)], side="accent", top="accent")
    head.block_u(fr, 0.0, -2.2, 0.2, 1.3, (2.3, 1.5), (2.1, 1.2), top_shift_f=-0.1,
                 tags={"all": "accent", "bottom": None, "fore": None})

    gun = d.Frame(origin=(0.0, -2.0, 0.9), elev=ELEV)
    head.block_f(gun, 0.0, 0.0, -0.4, 0.75, (1.7, 1.3), (1.4, 1.05), tags={"all": "trim", "back": None})
    head.block_f(gun, 0.0, 0.0, 0.7, 1.8, (0.95, 0.95), (0.82, 0.82), tags={"all": "trim", "back": None, "front": None})
    head.tube_f(gun, 6, 0.4, 1.75, 3.7, side="body")
    head.block_f(gun, 0.0, 0.0, 3.55, 4.15, (1.2, 0.82), (1.1, 0.74), tags={"all": "trim"})
    head.cone_f(gun, 4, 0.34, 4.15, 0.45)

    objects = d.base_objects(base, KEY, "trim")
    objects += d.head_objects(head, (0.0, 0.0, SWIVEL_Z), KEY, glow_color=d.PLASMA_GLOW)
    return objects
