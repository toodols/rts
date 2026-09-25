"""The tachyon accelerator barrel, shared by the two guns that fire BAR's tachyon beam: the Pulsar (cordoom) tower
and the Starlight (armmanni) tank. Both build it here, the Starlight's at a fraction of the Pulsar's size, so the
one weapon always looks like the one weapon.

A dark six-sided barrel, open at its breech (buried in its housing), ringed by two glowing coils (square collars
turned 45 degrees) and ending in a glowing four-sided tip: 40 triangles.
"""

import math

from . import defense_b_common as d

GLOW = (0.2, 0.8, 1.0, 1.0)  # tachyon cyan

# the Pulsar's barrel, in studs at scale 1, measured forward from its breech
RADIUS = 0.55
LENGTH = 7.6
COILS = (1.7, 4.0)  # each coil's back face, from the breech
COIL_SIZE = 1.35
COIL_DEPTH = 0.7
TIP_SIZE = 1.0
TIP_LENGTH = 0.9


def reach(scale=1.0):
    """How far forward of its breech the barrel's tip ends."""
    return (LENGTH + TIP_LENGTH) * scale


def barrel(breech, scale=1.0, trim=d.trim, glow=None):
    """The barrel pointing forward (-Y) from `breech`, in world space, `scale` times the Pulsar's. `trim` paints the
    dark barrel and `glow` the coils and tip. Returns (barrel, [coil, coil, tip])."""
    bx, by, bz = breech
    s = scale
    tube = trim(d.prism("barrel", RADIUS * s, LENGTH * s, 6, origin=breech, cap_top=False))
    d.forward([tube], breech)
    lit = []
    for y in COILS:
        at = (bx, by - y * s, bz)
        coil = d.block("coil", COIL_SIZE * s, COIL_SIZE * s, COIL_DEPTH * s, origin=at, cap_bottom=True)
        coil.rotation_euler = (0.0, 0.0, math.radians(45.0))
        lit.append(d.forward([coil], at)[0])
    at = (bx, by - LENGTH * s, bz)
    lit.append(d.forward([d.pyramid("tip", TIP_SIZE * s, TIP_SIZE * s, TIP_LENGTH * s, origin=at)], at)[0])
    if glow is not None:
        for o in lit:
            glow(o)
    return tube, lit
