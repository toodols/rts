"""unit_defs/air_t1.luau `hercules` (BAR corvalk): the light transport.

Collider capsule(40, 20, 56): radius 56/22 = 2.55 studs, height 20/11 = 1.82. Faceted low-poly, under 100
triangles. A flying cargo box on four lift fans: a squared-off fuselage with a cockpit on its sloped nose, two
cross beams carrying four flared fan housings at its corners (beams and housings are the team-coloured accent),
each with a dark rotor across its glowing mouth -- four fans is what reads as "transport"
from above -- and a dark cargo clamp under the belly. Nothing moves.
"""

import math

from . import air_t1_common as air
from . import common

ACCENT = air.rgb(226, 178, 74)
RADIUS, HEIGHT = 56 / 22, 20 / 11


def generate(params):
    zc = 1.0
    objects = []

    # Squared fuselage (sides=4 with flats up): a small blunt nose face, the full section just behind the
    # cockpit, and a slightly narrower tail face.
    body = air.loft("fuselage", [
        (-1.55, zc - 0.08, 0.30, 0.22),
        (-0.85, zc, 0.56, 0.44),
        (1.55, zc + 0.04, 0.46, 0.36),
    ], sides=4)
    common.body_mat(body)
    objects.append(body)

    # Cockpit glazing on the sloped nose (open underneath, inside the body).
    canopy = air.poly("canopy", [
        (0.0, -1.47, zc + 0.10),
        (0.30, -1.02, zc + 0.24),
        (-0.30, -1.02, zc + 0.24),
        (0.0, -0.95, zc + 0.36),
    ], [(0, 1, 3), (0, 3, 2), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents, glows, trims = [], [], []
    fx, fy = 1.45, 1.00  # fan centres
    half_bottom, half_top, fan_h = 0.40, 0.50, 0.30
    z0 = zc - 0.10
    for sy in (-1.0, 1.0):
        beam = air.beam(f"beam_{sy:+.0f}", (-fx, sy * fy, zc + 0.02), (fx, sy * fy, zc + 0.02), 0.22, 0.16)
        air.drop_faces(beam, [0, 1])  # both ends are buried in the fan housings
        accents.append(beam)
        for sx in (-1.0, 1.0):
            cx, cy = sx * fx, sy * fy
            housing = air.block(f"fan_{sx:+.0f}{sy:+.0f}", half_bottom * 2, half_bottom * 2, fan_h,
                                half_top * 2, half_top * 2, origin=(cx, cy, z0))
            air.drop_faces(housing, [0, 1])  # open top and bottom: the glowing fan fills the mouth
            accents.append(housing)
            # the fan's glowing disc filling the housing's mouth (it also closes the open box: Roblox draws no
            # back faces, so an open mouth would show straight through), a dark two-bladed rotor over it
            glows.append(air.plate(f"fan_glow_{sx:+.0f}{sy:+.0f}", (cx, cy, z0 + fan_h - 0.03),
                                   (half_top * 0.97, 0, 0), (0, half_top * 0.97, 0), (0, 0, 1)))
            a = math.radians(30.0 + 50.0 * sx + 25.0 * sy)
            ca, sa = math.cos(a), math.sin(a)
            trims.append(air.plate(f"rotor_{sx:+.0f}{sy:+.0f}", (cx, cy, z0 + fan_h - 0.01),
                                   (half_top * 0.92 * ca, half_top * 0.92 * sa, 0), (-0.08 * sa, 0.08 * ca, 0), (0, 0, 1)))

    # Rear jet for forward flight.
    glows.append(air.plate("tail_exhaust", (0.0, 1.555, zc + 0.04), (0.2, 0, 0), (0, 0, 0.15), (0, 1, 0)))

    # Cargo clamp under the belly: a dark tapered cradle (open on top, against the hull).
    trims.append(air.block("clamp", 0.50, 1.40, 0.26, 0.70, 1.70, origin=(0.0, 0.15, zc - 0.56)))
    air.drop_faces(trims[-1], [1])

    for obj in accents:
        air.accent_mat(obj, "hercules", ACCENT)
    for obj in glows:
        air.glow_mat(obj)
    for obj in trims:
        common.trim_mat(obj)
    objects += accents + glows + trims

    air.flat(objects)
    air.check_fit(objects, RADIUS, HEIGHT, "hercules")
    return objects
