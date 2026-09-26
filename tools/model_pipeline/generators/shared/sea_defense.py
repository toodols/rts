"""Shared pieces for the floating defences: urchin, coral and slingshot (unit_defs/defense.luau).

They float, so each model's origin is the water's surface (build.py lets a floating def reach below it). Each rides
on a float hull: dark sides flaring out from below the waterline to a deck, the gunmetal deck on top, and nothing
under it, as nobody sees the underside of what floats. What stands on the deck is the tower line's own
(shared/tower.py, shared/defense_a.py), so a Coral reads as a Warden and a Slingshot as a Thistle, afloat.
"""

import math

from . import defense_a as d

# How far below the surface a hull reaches, and how high its deck stands, for a one-cell footprint.
KEEL = -0.5
DECK = 0.45


def hull(parts, width, sides=8, keel=KEEL, deck=DECK, tuck=0.82):
    """A float hull into `parts` (a defense_a.Parts), `width` studs across its deck's flats: `sides` dark sides from
    the keel, `tuck` as wide, flaring out to the deck, and the deck's own face on top. 3 triangles a side, less 2."""
    # an n-gon's radius for flats `width` apart
    radius = width / 2.0 / math.cos(math.pi / sides)
    parts.loft([d.ngon(sides, radius * tuck, keel), d.ngon(sides, radius, deck)], side="trim", top="body")
    return deck
