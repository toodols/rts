"""What the pool skin's floats share (src/shared/skins/pool.luau): a fat inflatable ring lying flat about its own middle,
its hole straight up, the ring RING out and its tube TUBE across either way, so that every float fits a unit the same
way (client/donuts.luau scales each by its hole, RING - TUBE). The floats are not units, so their origin is their very
middle, and each sets RECENTRE = False.

pool_donut.py, the first of them, predates this module and builds its own ring the same way.
"""

import math

import bmesh

from . import common

RING = 1.0
TUBE = 0.42


def point(a, b):
    """The point `a` round the ring and `b` round the tube (0 facing out, a quarter turn on top)."""
    r = RING + TUBE * math.cos(b)
    return (r * math.cos(a), r * math.sin(a), TUBE * math.sin(b))


def ring(name, segments, sides, keep):
    """The quads of a ring `segments` round and `sides` round its tube for which `keep(i, j)` is true, i the segment
    round the ring and j the side round the tube (side 0 starts facing out and goes up over the top), as one object,
    shaded smooth. Faces face out of the tube."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    verts = {}

    def vert(i, j):
        key = (i % segments, j % sides)
        if key not in verts:
            verts[key] = bm.verts.new(point(2.0 * math.pi * key[0] / segments, 2.0 * math.pi * key[1] / sides))
        return verts[key]

    for i in range(segments):
        for j in range(sides):
            if keep(i, j):
                bm.faces.new((vert(i, j), vert(i + 1, j), vert(i + 1, j + 1), vert(i, j + 1)))
    bm.to_mesh(obj.data)
    bm.free()
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def ball(name, radius, origin, around=8, rows=4):
    """A low-poly ball, `around` segments round and `rows` from pole to pole, shaded smooth. Built vertex by vertex in
    a fixed order: Blender's own uv sphere came back with its vertices in a different order each build, which changed
    its hash, and so which upload it is found by."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    top = bm.verts.new((0.0, 0.0, radius))
    bands = []
    for row in range(1, rows):
        polar = math.pi * row / rows
        band = []
        for i in range(around):
            a = 2.0 * math.pi * i / around
            band.append(
                bm.verts.new(
                    (radius * math.sin(polar) * math.cos(a), radius * math.sin(polar) * math.sin(a), radius * math.cos(polar))
                )
            )
        bands.append(band)
    bottom = bm.verts.new((0.0, 0.0, -radius))
    for i in range(around):
        j = (i + 1) % around
        bm.faces.new((top, bands[0][i], bands[0][j]))
        for upper, lower in zip(bands, bands[1:]):
            bm.faces.new((upper[i], lower[i], lower[j], upper[j]))
        bm.faces.new((bands[-1][i], bottom, bands[-1][j]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    obj.location = origin
    return obj


def spike(name, base, length, tip_direction, origin):
    """A four-sided spike `base` across and `length` long, pointing along the unit vector `tip_direction` (only the
    axes: (0, -1, 0) and the like) from `origin`: a beak, a tail."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    dx, dy, dz = tip_direction
    # two axes across the spike, square to where it points
    if abs(dz) > 0.5:
        across = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0))
    elif abs(dy) > 0.5:
        across = ((1.0, 0.0, 0.0), (0.0, 0.0, 1.0))
    else:
        across = ((0.0, 1.0, 0.0), (0.0, 0.0, 1.0))
    h = base / 2.0
    corners = []
    for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
        u, v = across
        corners.append(bm.verts.new(tuple(u[k] * su * h + v[k] * sv * h for k in range(3))))
    tip = bm.verts.new((dx * length, dy * length, dz * length))
    for i in range(4):
        bm.faces.new((corners[i], corners[(i + 1) % 4], tip))
    bm.faces.new(list(reversed(corners)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj
