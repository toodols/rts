"""unit_defs `persecutor`: advanced plasma artillery, 3x3x3 cells (12x12x12 studs). Under 100 triangles.

The Agitator's big brother, made distinct by shape rather than size alone: a two-stepped sloped plinth, and
on it a broad, angular armored housing (not the Agitator's round dome) with a bustle at the back and two
long gunmetal barrels side by side, lobbing forward and up out of one wide dark mantlet, each ending in a
heavy muzzle brake with the plasma glowing at its tip. The whole head yaws with weapon 1.
"""

from . import defense_a_common as d

KEY = "persecutor"
TIER_Z = 1.8
SWIVEL_Z = 3.0
ELEV = 35.0


def generate(params):
    base = d.Parts()
    base.loft([d.square(11.7, 0.0), d.square(9.0, TIER_Z)], side="trim", top="body")
    base.loft([d.square(7.4, TIER_Z), d.square(6.4, SWIVEL_Z)], side="body", top="trim")

    head = d.Parts()
    fr = d.Frame()
    head.block_u(fr, 0.0, 0.2, 0.0, 2.4, (5.4, 6.0), (4.0, 3.8), top_shift_f=-0.6, tags={"all": "accent", "bottom": None})
    head.block_u(fr, 0.0, -3.2, 0.4, 2.0, (3.6, 1.5), (3.3, 1.2), top_shift_f=-0.1,
                 tags={"all": "accent", "bottom": None, "fore": None})

    gun = d.Frame(origin=(0.0, -2.3, 1.4), elev=ELEV)
    head.block_f(gun, 0.0, 0.0, -0.5, 0.85, (3.4, 1.8), (3.0, 1.5), tags={"all": "trim", "back": None})
    for x in (-0.85, 0.85):
        head.tube_f(gun, 6, 0.42, 0.8, 5.45, x=x, side="body")
        head.block_f(gun, x, 0.0, 5.3, 6.05, (1.0, 0.95), (0.92, 0.86), tags={"all": "trim", "back": None, "bottom": None})
        head.cone_f(gun, 4, 0.36, 6.05, 0.5, x=x)

    objects = d.base_objects(base, KEY, "trim")
    objects += d.head_objects(head, (0.0, 0.0, SWIVEL_Z), KEY, glow_color=d.PLASMA_GLOW)
    return objects
