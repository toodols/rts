"""Shared helpers for the T3 experimentals (unit_defs/t3.luau): juggernaut, vanguard, shiva.

Every model here is held to 100 triangles, so they are built from a handful of tapered blocks and open-ended
prisms whose hidden faces are left off (air_t1_common has the block / beam / plate / drop_faces primitives).
This adds tube(): an n-sided prism between two points that can taper to a point and skip either end cap,
which is what a mech's limbs are made of at 3 to 6 triangles a segment.
"""

import math

import mathutils

from . import air_t1_common as air
from . import common


def mat(obj, kind, def_name=None, color=None):
    """kind: body, trim, accent (needs def_name and color), glow (color optional)."""
    if kind == "body":
        common.body_mat(obj)
    elif kind == "trim":
        common.trim_mat(obj)
    elif kind == "accent":
        common.apply_material(obj, f"t3_accent_{def_name}", color, roughness=0.4, metallic=0.15)
    elif kind == "glow":
        glow = color or (1.0, 0.45, 0.12, 1.0)
        name = "t3_glow" if color is None else f"t3_glow_{def_name}"
        common.apply_material(obj, name, glow, roughness=0.2, metallic=0.0, emission=1.0)
    return obj


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


def drop_facing(obj, direction, threshold=0.9):
    """Deletes the faces that look along `direction` (world space, e.g. (0, 0, -1) for undersides the RTS
    camera never sees). Returns obj."""
    import bmesh
    import bpy

    bpy.context.view_layer.update()
    d = mathutils.Vector(direction).normalized()
    rot = obj.matrix_world.to_3x3()
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.normal_update()
    doomed = [f for f in bm.faces if (rot @ f.normal).normalized().dot(d) > threshold]
    bmesh.ops.delete(bm, geom=doomed, context="FACES_ONLY")
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def leg_piece(name, parts, hip, kind, group, def_name=None, color=None, **meta):
    """Joins a leg's parts (built in world space) into one object of one material, with its origin moved onto
    the hip joint `hip` -- the point a kind="leg" piece swings about -- and marks it as its own piece."""
    for obj in parts:
        obj.data.materials.clear()
        mat(obj, kind, def_name, color)
    leg = common.merge(name, parts)
    for v in leg.data.vertices:
        v.co.x -= hip[0]
        v.co.y -= hip[1]
        v.co.z -= hip[2]
    leg.location = hip
    return common.art_group(leg, group, pivot=True, kind="leg", **meta)
