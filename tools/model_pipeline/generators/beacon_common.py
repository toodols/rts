"""Shared builder for the scavenger beacons: scavenger_beacon (on land) and scavenger_sea_beacon (floating).

unit_defs/building.luau gives both a 3x4x3 cell collider (12 wide, 16 tall, 12 long) and the scavengers'
purple (Color3.fromRGB(150, 70, 200)). They are summoning structures, so they look nothing like the tidy
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
from . import economy_common as eco


def _core(objects, z, r):
    """The glowing core: a tall octahedron (8 triangles)."""
    core = eco.Mesh()
    ring = eco.at(eco.ngon(r, 4, math.pi / 4), z)
    core.pyramid(ring, (0.0, 0.0, z + r * 1.6))
    core.pyramid(list(reversed(ring)), (0.0, 0.0, z - r * 1.6))
    objects.append(eco.glow(core.build("core"), "scav", eco.SCAV_GLOW, emission=1.2))


def _shards(objects, z, radius, size, speed, phase=90.0):
    """Three thin bipyramid shards orbiting the core, as one spinning piece pivoting on the core's axis."""
    shards = eco.Mesh()
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
    piece = eco.accent(shards.build("shards", location=(0.0, 0.0, z)), "scav", eco.SCAV)
    objects.append(common.art_group(piece, "shards", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=speed))


def generate(params, sea):
    w = float(params.get("width", 12.0))
    height = float(params.get("height", 16.0))
    s = w / 12.0
    objects = []

    if not sea:
        # hexagonal dark plinth, and a spiked altar under the core
        base_h = 1.2 * s
        plinth = eco.Mesh().frustum(eco.ngon(6.4 * s, 6, math.pi / 6), eco.ngon(5.4 * s, 6, math.pi / 6), 0.0, base_h)
        objects.append(eco.scav_dark(plinth.build("plinth")))

        dark = eco.Mesh()
        dark.pyramid(eco.at(eco.ngon(2.8 * s, 4, math.pi / 4), base_h), (0.0, 0.0, base_h + 4.0 * s))
        core_z = 8.0 * s
        # three claws rising from the plinth's edge and curling in over the core
        claws = eco.Mesh()
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
        objects.append(eco.accent(claws.build("claws"), "scav", eco.SCAV))
        objects.append(eco.scav_dark(dark.build("altar")))
        _core(objects, core_z, 1.6 * s)
        _shards(objects, core_z, 3.2 * s, 1.3 * s, 0.8)
    else:
        # the buoy hull: sloped hexagonal sides running under the waterline, capped deck
        deck_z = 1.0 * s
        hull = eco.Mesh().frustum(eco.ngon(5.0 * s, 6, math.pi / 6), eco.ngon(6.4 * s, 6, math.pi / 6), -0.8 * s, deck_z)
        objects.append(eco.scav_dark(hull.build("hull")))
        # a glowing summoning ring inlaid in the deck, round the altar
        circle = eco.Mesh().poly(eco.at(eco.ngon(4.2 * s, 6), deck_z + 0.02 * s))
        objects.append(eco.glow(circle.build("summoning_circle"), "scav", eco.SCAV_GLOW, emission=1.2))

        dark = eco.Mesh()
        # a spike of an altar in the middle of the deck
        dark.pyramid(eco.at(eco.ngon(1.6 * s, 3, math.pi / 2), deck_z), (0.0, 0.0, deck_z + 4.2 * s))
        # the crown the legs meet at, and its spike, high above
        crown_z = height - 2.6 * s
        crown = eco.at(eco.ngon(1.3 * s, 3, -math.pi / 2), crown_z)
        dark.pyramid(list(reversed(crown)), (0.0, 0.0, crown_z - 1.8 * s))
        dark.pyramid(crown, (0.0, 0.0, height + 0.6 * s))
        objects.append(eco.scav_dark(dark.build("spikes")))

        legs = eco.Mesh()
        for i in range(3):
            a = math.radians(90.0 + 120.0 * i)
            m = eco.matrix(rotation=(0.0, 0.0, a - math.pi / 2))
            r0 = 5.0 * s
            bottom = eco.at(eco.rect(1.4 * s, 1.2 * s, (0.0, r0)), deck_z)
            top = eco.at(eco.rect(0.5 * s, 0.45 * s, (0.0, 1.2 * s)), crown_z + 0.4 * s)
            # the leg's top end sits inside the crown
            legs.loft(bottom, top, m, cap_b=False)
            # a barbed float fin on each leg's foot
            legs.pyramid([(0.5 * s, r0 + 0.6 * s, deck_z), (-0.5 * s, r0 + 0.6 * s, deck_z), (0.0, r0 + 0.3 * s, deck_z + 2.2 * s)], (0.0, r0 + 1.3 * s, deck_z + 0.2 * s), m)
        objects.append(eco.accent(legs.build("legs"), "scav", eco.SCAV))
        core_z = 8.5 * s
        _core(objects, core_z, 1.5 * s)
        _shards(objects, 5.6 * s, 2.8 * s, 1.2 * s, -0.8, phase=30.0)  # low, inside the legs, over the altar

    return objects
