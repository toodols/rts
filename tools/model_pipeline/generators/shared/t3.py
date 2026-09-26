"""Shared helpers for the T3 experimentals (unit_defs/t3.luau): juggernaut, vanguard, shiva.

Every model here is held to 100 triangles, so they are built from a handful of tapered blocks and open-ended
prisms whose hidden faces are left off (air_t1 has the block / beam / plate primitives).
This adds tube(): an n-sided prism between two points that can taper to a point and skip either end cap,
which is what a mech's limbs are made of at 3 to 6 triangles a segment.
"""

import math

import mathutils

from . import air_t1 as air
from . import common


def tube(name, a, b, radius, sides=3, radius2=None, open_start=True, open_end=False, roll=0.0, up=(0.0, 0.0, 1.0)):
    """An n-sided prism from a to b: radius at a, radius2 at b (0 makes a point). The ring's first corner
    points along `up` (projected off the axis), turned by `roll` radians. End caps are skipped where open."""
    a, b = mathutils.Vector(a), mathutils.Vector(b)
    axis = (b - a).normalized()
    u = mathutils.Vector(up)
    u = (u - axis * u.dot(axis))
    if u.length < 1e-6:
        u = mathutils.Vector((0.0, 1.0, 0.0))
        u = (u - axis * u.dot(axis))
    u.normalize()
    v = axis.cross(u)
    r2 = radius if radius2 is None else radius2

    def ring(center, r):
        pts = []
        for i in range(sides):
            t = roll + 2.0 * math.pi * i / sides
            pts.append(tuple(center + (u * math.cos(t) + v * math.sin(t)) * r))
        return pts

    verts = ring(a, radius)
    faces = []
    if r2 < 1e-6:
        verts.append(tuple(b))
        tip = sides
        for i in range(sides):
            faces.append((i, (i + 1) % sides, tip))
    else:
        verts += ring(b, r2)
        for i in range(sides):
            j = (i + 1) % sides
            faces.append((i, j, sides + j, sides + i))
        if not open_end:
            faces.append(tuple(range(sides, 2 * sides)))
    if not open_start:
        faces.append(tuple(range(sides)))
    return air.poly(name, verts, faces)


def wedge(name, bx, by, h, ridge_y, origin=(0.0, 0.0, 0.0), ridge_x=None, open_bottom=True):
    """A ramp: a bx by by rectangle on the ground at `origin` rising to a ridge line (running along X, ridge_x
    wide, default the full width) at height h and y offset ridge_y. The front (-Y) side is a slope, the back
    a steeper face; 6 triangles without its bottom. Feet, glacis plates, cowls."""
    ox, oy, oz = origin
    hx, hy = bx / 2.0, by / 2.0
    rx = hx if ridge_x is None else ridge_x / 2.0
    verts = [
        (ox - hx, oy - hy, oz), (ox + hx, oy - hy, oz), (ox + hx, oy + hy, oz), (ox - hx, oy + hy, oz),
        (ox - rx, oy + ridge_y, oz + h), (ox + rx, oy + ridge_y, oz + h),
    ]
    faces = [(0, 1, 5, 4), (2, 3, 4, 5), (1, 2, 5), (3, 0, 4)]
    if not open_bottom:
        faces.append((3, 2, 1, 0))
    return air.poly(name, verts, faces)


def leg_piece(name, parts, hip, paint, group, **meta):
    """Joins a leg's parts (built in world space) into one object of one material, `paint` (a common.Materials paint,
    like m.trim), with its origin moved onto the hip joint `hip` -- the point a kind="leg" piece swings about -- and
    marks it as its own piece."""
    for obj in parts:
        obj.data.materials.clear()
        paint(obj)
    leg = common.merge(name, parts)
    for v in leg.data.vertices:
        v.co.x -= hip[0]
        v.co.y -= hip[1]
        v.co.z -= hip[2]
    leg.location = hip
    return common.art_group(leg, group, pivot=True, kind="leg", **meta)
