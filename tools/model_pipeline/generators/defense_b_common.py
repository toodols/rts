"""Lean shared pieces for the heavy Cortex defenses: pulsar, catalyst, apocalypse, prevailer, calamity, overseer.

These models are held to 100 triangles each, the whole model, so nothing here bevels, and every primitive builds
only the faces that can be seen: a piece standing on something has no bottom, a barrel whose breech is buried in
its turret has no back cap, a glowing strip on a wall is a single quad. The generators do not call
common.finish_all (its bevel multiplies triangles); faces are flat shaded.

Same language as the laser towers and the reactors: dark trim, gunmetal body, the def's colour as the team accent,
emissive glow for anything lit. Material names are prefixed "def_b_" so they never collide with another family's
cached material, and the team accent's name contains "accent" so the game tints it with the owner's colour.
"""

import math

import bmesh
import mathutils

from . import common

RUST = (0.776, 0.337, 0.282, 1.0)  # Color3.fromRGB(198, 86, 72): pulsar, catalyst, apocalypse, calamity
STEEL_BLUE = (0.392, 0.588, 0.784, 1.0)  # Color3.fromRGB(100, 150, 200): prevailer
SKY_BLUE = (0.376, 0.667, 0.839, 1.0)  # Color3.fromRGB(96, 170, 214): overseer


def body(obj):
    common.body_mat(obj)
    return obj


def trim(obj):
    common.trim_mat(obj)
    return obj


def accent(obj, key, color):
    common.apply_material(obj, f"def_b_accent_{key}", color, roughness=0.4, metallic=0.15)
    return obj


def glow(obj, key, color, strength=1.0):
    common.apply_material(obj, f"def_b_glow_{key}", color, roughness=0.15, emission=strength)
    return obj


def _mesh(name, rings, cap_bottom, cap_top):
    """An object lofted through `rings` (lists of points, each ring the same length, bottom to top, counter-
    clockwise seen from above): side quads between consecutive rings, and an n-gon cap on the first/last ring if
    asked."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    vrings = [[bm.verts.new(p) for p in ring] for ring in rings]
    n = len(rings[0])
    for a, b in zip(vrings, vrings[1:]):
        for i in range(n):
            j = (i + 1) % n
            bm.faces.new((a[i], a[j], b[j], b[i]))
    if cap_bottom:
        bm.faces.new(list(reversed(vrings[0])))
    if cap_top:
        bm.faces.new(vrings[-1])
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def _square(sx, sy, z, off=(0.0, 0.0), chamfer=0.0):
    hx, hy = sx / 2.0, sy / 2.0
    ox, oy = off
    if chamfer <= 0.0:
        pts = [(-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy)]
    else:
        c = chamfer
        pts = [(-hx + c, -hy), (hx - c, -hy), (hx, -hy + c), (hx, hy - c), (hx - c, hy), (-hx + c, hy), (-hx, hy - c),
               (-hx, -hy + c)]
    return [(x + ox, y + oy, z) for x, y in pts]


def block(name, size_x, size_y, size_z, origin=(0.0, 0.0, 0.0), top=None, top_offset=(0.0, 0.0), chamfer=0.0,
          cap_top=True, cap_bottom=False):
    """A box standing base-up from `origin` (no bottom face unless asked): 10 triangles, 12 with a bottom. `top` =
    (x, y) sizes its top face for a frustum; `top_offset` shifts it; `chamfer` cuts the corners at 45 degrees (8
    sides: 22 triangles)."""
    tx, ty = top if top is not None else (size_x, size_y)
    ctop = chamfer * min(tx / size_x, ty / size_y) if chamfer else 0.0
    rings = [_square(size_x, size_y, 0.0, chamfer=chamfer), _square(tx, ty, size_z, off=top_offset, chamfer=ctop)]
    obj = _mesh(name, rings, cap_bottom, cap_top)
    obj.location = origin
    return obj


def ngon_ring(radius, z, segments, phase=None):
    """Points of a regular polygon; by default turned so a flat, not a corner, faces -Y (the front)."""
    if phase is None:
        phase = -math.pi / 2.0 + math.pi / segments
    return [(radius * math.cos(phase + 2.0 * math.pi * i / segments),
             radius * math.sin(phase + 2.0 * math.pi * i / segments), z) for i in range(segments)]


def prism(name, radius, length, segments=6, radius2=None, origin=(0.0, 0.0, 0.0), cap_top=True, cap_bottom=False,
          phase=None):
    """A `segments`-sided prism (or frustum with radius2) standing base-up from `origin`: 2 triangles a side, and
    segments - 2 for each cap."""
    r2 = radius if radius2 is None else radius2
    obj = _mesh(name, [ngon_ring(radius, 0.0, segments, phase), ngon_ring(r2, length, segments, phase)], cap_bottom,
                cap_top)
    obj.location = origin
    return obj


def pyramid(name, base_x, base_y, height, origin=(0.0, 0.0, 0.0), apex=(0.0, 0.0)):
    """A four-sided pyramid (4 triangles, no bottom): a spike, a lamp, a nose cone."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    ring = [bm.verts.new(p) for p in _square(base_x, base_y, 0.0)]
    tip = bm.verts.new((apex[0], apex[1], height))
    for i in range(4):
        bm.faces.new((ring[i], ring[(i + 1) % 4], tip))
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def panel(name, centre, u, v):
    """One quad (2 triangles) at `centre` spanning +-u and +-v; it faces u x v. For glowing strips and windows laid
    just off a surface."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    c = mathutils.Vector(centre)
    u = mathutils.Vector(u)
    v = mathutils.Vector(v)
    vs = [bm.verts.new(c + a * u + b * v) for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    bm.faces.new(vs)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def bake(objs, matrix):
    """Bakes each object's own transform into its mesh, then applies `matrix` (world space) on top."""
    for obj in objs:
        obj.data.transform(obj.matrix_basis)
        obj.matrix_basis = mathutils.Matrix.Identity(4)
        obj.data.transform(matrix)
    return objs


def rotate_about(pivot, axis, degrees):
    """A matrix rotating by `degrees` about `axis` ("X", "Y" or "Z") through `pivot`."""
    return mathutils.Matrix.Translation(pivot) @ mathutils.Matrix.Rotation(math.radians(degrees), 4, axis) \
        @ mathutils.Matrix.Translation(-mathutils.Vector(pivot))


def forward(objs, pivot, rise=0.0):
    """Lays objects built standing up (+Z from `pivot`) down to point forward (-Y), then raises them `rise` degrees
    (the muzzle goes up)."""
    return bake(objs, rotate_about(pivot, "X", 90.0 - rise))


def merged(name, objs, origin=(0.0, 0.0, 0.0)):
    """common.merge, for pieces built in world space: the result keeps their world positions, with its origin at
    `origin` (a swivel or hinge point)."""
    obj = common.merge(name, objs, origin=(0.0, 0.0, 0.0))
    obj.data.transform(mathutils.Matrix.Translation(-mathutils.Vector(origin)))
    obj.location = origin
    return obj


def extrude(name, points, height, origin=(0.0, 0.0, 0.0), top_scale=1.0, cap_bottom=False, skip_sides=()):
    """A prism of any outline (`points` counter-clockwise seen from above, in x, y), standing base-up from
    `origin`: 2 triangles a side and len(points) - 2 for the top. `top_scale` shrinks the top about (0, 0);
    `skip_sides` lists side indices (side i runs from point i to i + 1) left open because nothing sees them."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    lo = [bm.verts.new((x, y, 0.0)) for x, y in points]
    hi = [bm.verts.new((x * top_scale, y * top_scale, height)) for x, y in points]
    n = len(points)
    for i in range(n):
        if i in skip_sides:
            continue
        j = (i + 1) % n
        bm.faces.new((lo[i], lo[j], hi[j], hi[i]))
    bm.faces.new(hi)
    if cap_bottom:
        bm.faces.new(list(reversed(lo)))
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def cone(name, radius, height, segments=6, origin=(0.0, 0.0, 0.0), phase=None):
    """A `segments`-sided cone to a point, no base: `segments` triangles."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    ring = [bm.verts.new(p) for p in ngon_ring(radius, 0.0, segments, phase)]
    tip = bm.verts.new((0.0, 0.0, height))
    for i in range(segments):
        bm.faces.new((ring[i], ring[(i + 1) % segments], tip))
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def disc(name, radius, segments, origin=(0.0, 0.0, 0.0), phase=None):
    """A flat, upward-facing regular polygon (segments - 2 triangles): the floor seen inside an open silo, so its
    single-sided walls do not show through when the hatch swings open."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    bm.faces.new([bm.verts.new(p) for p in ngon_ring(radius, 0.0, segments, phase)])
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj
