"""Shared builder for the scavenger beacons: scavenger_beacon (on land) and scavenger_sea_beacon (floating).

Both are in the scavengers' purple (their defs' colour). They are summoning structures, so they look nothing like the tidy
Cortex economy: near-black, spiked and asymmetric-feeling, a glowing violet core at the heart of each, and three
violet shards orbiting that core (their own rigid piece, common.art_group kind="spin" about the vertical).

- The land beacon is a hand of three great claws rising from a hexagonal dark plinth and curling in over the
  core, which hangs above a spiked altar; a thorn juts from each claw's back.
- The sea beacon is a buoy: a hexagonal hull riding the surface (its origin is the water's surface), a glowing
  summoning circle and a spike of an altar on its deck, and three long legs leaning in from the hull's
  corners to a crown high above, the core hanging beneath it.

Budget: 100 triangles each.
"""

import math

from . import common
from . import economy as eco
from . import palette


def _core(objects, z, r):
    """The glowing core: a tall octahedron (8 triangles)."""
    core = common.Faces()
    ring = common.at(common.ngon(4, r, math.pi / 4), z)
    core.pyramid(ring, (0.0, 0.0, z + r * 1.6))
    core.pyramid(list(reversed(ring)), (0.0, 0.0, z - r * 1.6))
    objects.append(common.glow_mat(core.build("core"), palette.SCAVENGER))


def _shards(objects, accent, z, radius, size, speed, phase=90.0):
    """Three thin bipyramid shards orbiting the core, as one spinning piece pivoting on the core's axis."""
    shards = common.Faces()
    for i in range(3):
        a = math.radians(phase + 120.0 * i)
        x, y = math.cos(a) * radius, math.sin(a) * radius
        # a flat diamond ring, long along the orbit's tangent, with points above and below
        t = (-math.sin(a), math.cos(a))
        o = (math.cos(a), math.sin(a))
        ring = [
            (x + o[0] * size * 0.3, y + o[1] * size * 0.3, z),
            (x + t[0] * size * 0.45, y + t[1] * size * 0.45, z),
            (x - o[0] * size * 0.3, y - o[1] * size * 0.3, z),
            (x - t[0] * size * 0.45, y - t[1] * size * 0.45, z),
        ]
        shards.pyramid(ring, (x, y, z + size * 1.3))
        shards.pyramid(list(reversed(ring)), (x, y, z - size * 1.3))
    piece = common.accent_mat(shards.build_about("shards", (0.0, 0.0, z)), accent)
    objects.append(common.art_group(piece, "shards", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=speed))


def generate(params, sea):
    accent = params["color"]
    w = params["collider"]["width"]
    height = params["collider"]["height"]
    s = w / 12.0
    objects = []

    if not sea:
        # hexagonal dark plinth, and a spiked altar under the core
        base_h = 1.2 * s
        plinth = common.Faces().frustum(common.ngon(6, 6.4 * s, math.pi / 6), common.ngon(6, 5.4 * s, math.pi / 6), 0.0, base_h)
        objects.append(eco.scav_dark(plinth.build("plinth")))

        dark = common.Faces()
        dark.pyramid(common.at(common.ngon(4, 2.8 * s, math.pi / 4), base_h), (0.0, 0.0, base_h + 4.0 * s))
        core_z = 8.0 * s
        # three claws rising from the plinth's edge and curling in over the core
        claws = common.Faces()
        for i in range(3):
            a = math.radians(-90.0 + 120.0 * i)
            m = eco.matrix(rotation=(0.0, 0.0, a - math.pi / 2))  # local +Y outward at angle a
            r0, r1 = 4.6 * s, 4.9 * s
            z1 = 8.8 * s
            bottom = [(-0.95 * s, r0 - 0.8 * s, base_h), (0.95 * s, r0 - 0.8 * s, base_h), (0.8 * s, r0 + 0.8 * s, base_h), (-0.8 * s, r0 + 0.8 * s, base_h)]
            top = [(-0.6 * s, r1 - 0.45 * s, z1), (0.6 * s, r1 - 0.45 * s, z1), (0.5 * s, r1 + 0.45 * s, z1), (-0.5 * s, r1 + 0.45 * s, z1)]
            claws.loft(bottom, top, m, cap_b=False)
            # the talon: from the knuckle in toward the middle, over the core
            claws.pyramid(top, (0.0, 1.5 * s, height - 1.6 * s), m)
            # a thorn jutting out of each claw's back
            thorn_ring = [(0.4 * s, r1 + 0.1 * s, 4.6 * s), (-0.4 * s, r1 + 0.1 * s, 4.6 * s), (0.0, r1 + 0.1 * s, 5.6 * s)]
            claws.pyramid(thorn_ring, (0.0, r1 + 1.5 * s, 3.8 * s), m)
        objects.append(common.accent_mat(claws.build("claws"), accent))
        objects.append(eco.scav_dark(dark.build("altar")))
        _core(objects, core_z, 1.6 * s)
        _shards(objects, accent, core_z, 3.2 * s, 1.3 * s, 0.8)
    else:
        # the buoy hull: sloped hexagonal sides running under the waterline, capped deck
        deck_z = 1.0 * s
        hull = common.Faces().frustum(common.ngon(6, 5.0 * s, math.pi / 6), common.ngon(6, 6.4 * s, math.pi / 6), -0.8 * s, deck_z)
        objects.append(eco.scav_dark(hull.build("hull")))
        # a glowing summoning ring inlaid in the deck, round the altar
        circle = common.Faces().polygon(common.at(common.ngon(6, 4.2 * s), deck_z + 0.02 * s))
        objects.append(common.glow_mat(circle.build("summoning_circle"), palette.SCAVENGER))

        dark = common.Faces()
        # a spike of an altar in the middle of the deck
        dark.pyramid(common.at(common.ngon(3, 1.6 * s, math.pi / 2), deck_z), (0.0, 0.0, deck_z + 4.2 * s))
        # the crown the legs meet at, and its spike, high above
        crown_z = height - 2.6 * s
        crown = common.at(common.ngon(3, 1.3 * s, -math.pi / 2), crown_z)
        dark.pyramid(list(reversed(crown)), (0.0, 0.0, crown_z - 1.8 * s))
        dark.pyramid(crown, (0.0, 0.0, height + 0.6 * s))
        objects.append(eco.scav_dark(dark.build("spikes")))

        legs = common.Faces()
        for i in range(3):
            a = math.radians(90.0 + 120.0 * i)
            m = eco.matrix(rotation=(0.0, 0.0, a - math.pi / 2))
            r0 = 5.0 * s
            bottom = common.at(common.rect(1.4 * s, 1.2 * s, (0.0, r0)), deck_z)
            top = common.at(common.rect(0.5 * s, 0.45 * s, (0.0, 1.2 * s)), crown_z + 0.4 * s)
            # the leg's top end sits inside the crown
            legs.loft(bottom, top, m, cap_b=False)
            # a barbed float fin on each leg's foot
            legs.pyramid([(0.5 * s, r0 + 0.6 * s, deck_z), (-0.5 * s, r0 + 0.6 * s, deck_z), (0.0, r0 + 0.3 * s, deck_z + 2.2 * s)], (0.0, r0 + 1.3 * s, deck_z + 0.2 * s), m)
        objects.append(common.accent_mat(legs.build("legs"), accent))
        core_z = 8.5 * s
        _core(objects, core_z, 1.5 * s)
        _shards(objects, accent, 5.6 * s, 2.8 * s, 1.2 * s, -0.8, phase=30.0)  # low, inside the legs, over the altar

    return objects
