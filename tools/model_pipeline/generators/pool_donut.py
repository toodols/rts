"""The pool skin's pool donut (src/shared/skins/pool.luau): an inflatable swim ring, worn round a unit's waist.

A fat vinyl ring striped in the team's colour and white, with a little valve on top. It lies flat in the ground plane,
its hole straight up, and its origin is its very middle (not the ground: it is never stood on anything), with the ring
1 unit out and the tube TUBE across it either way; client/donuts.luau scales it to the unit wearing it. Everything is
one static piece. The team-coloured stripes are its accent, so they take the team's colour.
"""

import math

import bmesh

from . import common

# it is worn by every unit at once, so it is kept small, if a little over a unit's usual budget, to stay round
MAX_TRIANGLES = 170
RECENTRE = False

RING = 1.0
TUBE = 0.42
SEGMENTS = 12  # round the ring
SIDES = 6  # round the tube
STRIPES = 6  # alternating team-coloured and white, SEGMENTS / STRIPES segments each

ACCENT_COLOR = (0.9, 0.22, 0.2, 1.0)
WHITE_COLOR = (0.96, 0.96, 0.94, 1.0)
VALVE_COLOR = (0.8, 0.8, 0.78, 1.0)


def point(a, b):
    """The point `a` round the ring and `b` round the tube (0 facing out, a quarter turn on top)."""
    r = RING + TUBE * math.cos(b)
    return (r * math.cos(a), r * math.sin(a), TUBE * math.sin(b))


def arcs(name, stripes):
    """The stripes numbered in `stripes`, as one object: each is a length of the tube, open at both ends where its
    neighbours join on."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    per = SEGMENTS // STRIPES
    for stripe in stripes:
        rows = []
        for i in range(stripe * per, stripe * per + per + 1):
            a = 2.0 * math.pi * i / SEGMENTS
            rows.append([bm.verts.new(point(a, 2.0 * math.pi * j / SIDES)) for j in range(SIDES)])
        for here, there in zip(rows, rows[1:]):
            for j in range(SIDES):
                k = (j + 1) % SIDES
                bm.faces.new((here[j], there[j], there[k], here[k]))
    bm.to_mesh(obj.data)
    bm.free()
    # the faces go round the tube counter-clockwise seen from outside it, so they face out; smooth, like vinyl
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def generate(params):
    accent = arcs("stripes_accent", range(0, STRIPES, 2))
    common.apply_material(accent, "pool_donut_accent", ACCENT_COLOR, roughness=0.25)
    white = arcs("stripes_white", range(1, STRIPES, 2))
    common.apply_material(white, "pool_donut_white", WHITE_COLOR, roughness=0.25)

    # the valve, on top of the tube halfway through a white stripe
    per = SEGMENTS // STRIPES
    a = 2.0 * math.pi * (per + per / 2) / SEGMENTS
    valve = common.cylinder("valve", TUBE * 0.16, TUBE * 0.22, origin=(RING * math.cos(a), RING * math.sin(a), TUBE * 0.98), segments=6)
    common.apply_material(valve, "pool_donut_valve", VALVE_COLOR, roughness=0.4)
    return [accent, white, valve]
