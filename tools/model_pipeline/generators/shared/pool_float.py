"""What the pool skin's floats share (src/shared/skins/pool.luau): a fat inflatable ring lying flat about its own middle,
its hole straight up, the ring RING out and its tube TUBE across either way, so that every float fits a unit the same
way (client/donuts.luau scales each by its hole, RING - TUBE). The floats are not units, so their origin is their very
middle (a "prop" places its own origin).
"""

import math


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
    points = []
    index = {}

    def vert(i, j):
        key = (i % segments, j % sides)
        if key not in index:
            index[key] = len(points)
            points.append(point(2.0 * math.pi * key[0] / segments, 2.0 * math.pi * key[1] / sides))
        return index[key]

    faces = [
        (vert(i, j), vert(i + 1, j), vert(i + 1, j + 1), vert(i, j + 1))
        for i in range(segments)
        for j in range(sides)
        if keep(i, j)
    ]
    return smooth(common.mesh(name, points, faces))


def smooth(obj):
    """Shades every face of `obj` smooth: a float is soft, not faceted."""
    for polygon in obj.data.polygons:
        polygon.use_smooth = True
    return obj


def ball(name, radius, origin, around=8, rows=4):
    """A low-poly ball, `around` segments round and `rows` from pole to pole, shaded smooth. Built vertex by vertex in
    a fixed order: Blender's own uv sphere came back with its vertices in a different order each build, which changed
    its hash, and so which upload it is found by."""
    points = [(0.0, 0.0, radius)]
    bands = []
    for row in range(1, rows):
        polar = math.pi * row / rows
        band = []
        for i in range(around):
            a = 2.0 * math.pi * i / around
            band.append(len(points))
            points.append(
                (radius * math.sin(polar) * math.cos(a), radius * math.sin(polar) * math.sin(a), radius * math.cos(polar))
            )
        bands.append(band)
    points.append((0.0, 0.0, -radius))
    top, bottom = 0, len(points) - 1
    faces = []
    for i in range(around):
        j = (i + 1) % around
        faces.append((top, bands[0][i], bands[0][j]))
        for upper, lower in zip(bands, bands[1:]):
            faces.append((upper[i], lower[i], lower[j], upper[j]))
        faces.append((bands[-1][i], bottom, bands[-1][j]))
    return smooth(common.mesh(name, points, faces, origin, recalc_normals=True))


def spike(name, base, length, tip_direction, origin):
    """A four-sided spike `base` across and `length` long, pointing along the unit vector `tip_direction` (only the
    axes: (0, -1, 0) and the like) from `origin`: a beak, a tail."""
    dx, dy, dz = tip_direction
    # two axes across the spike, square to where it points
    if abs(dz) > 0.5:
        across = ((1.0, 0.0, 0.0), (0.0, 1.0, 0.0))
    elif abs(dy) > 0.5:
        across = ((1.0, 0.0, 0.0), (0.0, 0.0, 1.0))
    else:
        across = ((0.0, 1.0, 0.0), (0.0, 0.0, 1.0))
    h = base / 2.0
    u, v = across
    corners = [tuple(u[k] * su * h + v[k] * sv * h for k in range(3)) for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    faces = [(i, (i + 1) % 4, 4) for i in range(4)] + [(3, 2, 1, 0)]
    return common.mesh(name, corners + [(dx * length, dy * length, dz * length)], faces, origin, recalc_normals=True)
