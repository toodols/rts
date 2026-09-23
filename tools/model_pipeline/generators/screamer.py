"""unit_defs `screamer` (corscreamer): a long range anti-air missile tower, 2x2x2 cells (8x8x8 studs). Under 100
triangles.

The tower line's sloped plinth, broad, with the four hatches of its missile stockpile on the deck, a thick
tapered column, and on it an armored cradle holding two long launch tubes almost upright, the lit nose of a
big missile standing out of each. The whole head yaws with weapon 1.
"""

from . import defense_a_common as d

KEY = "screamer"
SWIVEL_Z = 3.0
DECK_Z = 1.4
ELEV = 62.0


def generate(params):
    base = d.Parts()
    base.loft([d.square(7.8, 0.0), d.square(6.2, DECK_Z)], side="trim", top="body")
    deck = d.Frame(origin=(0.0, 0.0, DECK_Z + 0.01))
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            base.quad_u(deck, sx * 2.25, sy * 2.25, 0.0, 1.0, 1.0, tag="trim")
    base.loft([d.square(2.6, DECK_Z), d.square(2.1, SWIVEL_Z)], side="body")

    head = d.Parts()
    fr = d.Frame()
    head.block_u(fr, 0.0, 0.0, 0.0, 2.1, (2.5, 3.0), (2.0, 2.1), top_shift_f=-0.35, tags={"all": "accent", "bottom": None})
    for side in (-1.0, 1.0):
        tube = d.Frame(origin=(side * 1.85, 0.0, 1.55), elev=ELEV)
        head.tube_f(tube, 6, 0.62, -2.2, 2.6, side="accent", back="trim")
        head.cone_f(tube, 6, 0.52, 2.6, 0.75)
        # a dark clamp where the tube is held to the cradle
        head.block_f(tube, 0.0, 0.0, -0.35, 0.35, (1.2, 1.34), tags={"all": "trim", "back": None, "front": None})

    objects = d.base_objects(base, KEY, "trim")
    objects += d.head_objects(head, (0.0, 0.0, SWIVEL_Z), KEY)
    return objects
