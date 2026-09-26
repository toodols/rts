"""unit_defs/vehicle_t2.luau `negotiator` (BAR's corvroc): Cortex's long-range rocket launcher.

The Arbiter's rocket on a truck: a flatbed on three axles of hexagonal wheels that roll as it drives, a
team-colour cab up front, and on the bed an erector holding one big rocket, raised off the bed, that goes
straight up, over and down."""

import math

from .shared import common
from .shared import palette
from .shared import vehicle_t2 as v

CATEGORY = "entity"
DEF = "negotiator"
MOUNTS = {
    1: {"pivot": (0, 1.1724, -0.334), "muzzle": (0, 1.6245, 1.0041)},
}

PITCH = 22.0  # the rocket's elevation on its erector, raised a little off the bed


def generate(params):
    m = common.Materials(params["color"], palette.HEADLIGHT)
    objects = []

    L, W = 3.3, 1.96
    hl, hw = L / 2.0, W / 2.0
    bed_z, bed_h = 0.44, 0.34
    deck = bed_z + bed_h

    # Footprint first: the flatbed, its front hidden by the cab (8 tris).
    bed = common.block("bed", W, L, bed_h, top=(W - 0.08, L - 0.04), at=(0.0, 0.0, bed_z), drop=("bottom", "front"))
    objects.append(m.body(bed))

    # Three axles, each a pair of hexagonal wheels rolling as one piece about its hub (20 tris an axle).
    wheel_r, wheel_z = 0.32, 0.33
    for i, y in enumerate((-1.1, 0.22, 1.16), start=1):
        wheels = v.axle(f"axle_{i}", (0.0, y, wheel_z), wheel_r, hw + 0.03)
        m.trim(wheels)
        objects.append(common.art_group(wheels, f"wheel_{i}", pivot=True, kind="wheel", axis=(1.0, 0.0, 0.0),
                                        radius=wheel_r))

    # Cab: sloped windscreen forward (10 tris) with a lit window across it (2).
    cy0, cy1, cz0, ch = -hl + 0.02, -hl + 0.95, deck, 0.72
    cab = common.block("cab", W - 0.04, cy1 - cy0, ch, top=(W - 0.34, 0.52), top_offset=(0.0, 0.16), at=(0.0, (cy0 + cy1) / 2.0, cz0), drop=('bottom',))
    objects.append(m.accent(cab))
    # the cab's front face runs from (y=cy0, z=cz0) up to (y=cy1 - 0.52 + 0.16 ..., z=cz0 + ch)
    fy_top = (cy0 + cy1) / 2.0 + 0.16 - 0.26
    lift_y, lift_z = -0.012, 0.004

    def front(x, t):
        return (x, cy0 + (fy_top - cy0) * t + lift_y, cz0 + ch * t + lift_z)

    up = (0.0, -ch, fy_top - cy0)
    objects.append(m.glow(v.decal("windscreen", [front(-0.72, 0.5), front(0.72, 0.5), front(0.66, 0.9),
                                                 front(-0.66, 0.9)], up=up)))

    # The launcher turns on the bed: the erector and the rocket with its nose cone.
    pivot = (0.0, 0.3, deck)
    d = v.direction(PITCH)
    # the erector: a wedge on the bed whose slope, hidden under the rocket, carries it (4 tris)
    ry0, ry1 = 1.25, -0.75
    rise = (ry0 - ry1) * math.tan(math.radians(PITCH))
    rail = v.mesh("erector", [(-0.23, ry1, 0.0), (-0.23, ry0, 0.0), (-0.23, ry1, rise),
                              (0.23, ry1, 0.0), (0.23, ry0, 0.0), (0.23, ry1, rise)],
                  [(0, 1, 2), (3, 4, 5), (0, 2, 5, 3)])
    m.trim(rail)
    rail = common.merge("launcher", [rail], origin=pivot)
    objects.append(common.art_group(rail, "turret_1", pivot=True, kind="turret", weapon=1))
    # the rocket rides on the erector's slope (18 tris)
    above = v.Vector((0.0, d.z, -d.y))
    base = v.Vector((0.0, ry0, 0.0)) + above * 0.2 - d * 0.1
    body, tip = v.rod("rocket", 0.21, 2.0, tuple(base), pitch=PITCH, front_cap=False, roll=0.0)
    nose, _ = v.rod("nose", 0.21, 0.5, tip, pitch=PITCH, front_cap=False, radius2=0.004, roll=0.0)
    for p in (body, nose):
        m.accent(p)
    rocket = common.merge("rocket", [body, nose], origin=pivot)
    objects.append(common.art_group(rocket, "turret_1", kind="turret", weapon=1))

    return objects
