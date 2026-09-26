"""Lean shared pieces for the heavy Cortex defenses: pulsar, catalyst, apocalypse, prevailer, calamity, overseer.

These models are held to 100 triangles each, the whole model, so nothing here bevels, and every primitive builds
only the faces that can be seen: a piece standing on something has no bottom, a barrel whose breech is buried in
its turret has no back cap, a glowing strip on a wall is a single quad.

Same language as the laser towers and the reactors: dark trim, gunmetal body, the def's colour as the team accent,
and a glow for anything lit (common.Materials).
"""

import math

import mathutils

from . import common


def _mesh(name, rings, cap_bottom, cap_top):
    """An object lofted through `rings` (lists of points, each ring the same length, bottom to top, counter-
    clockwise seen from above): side quads between consecutive rings, and an n-gon cap on the first/last ring if
    asked."""
    n = len(rings[0])
    index = [list(range(k * n, (k + 1) * n)) for k in range(len(rings))]
    faces = []
    for a, b in zip(index, index[1:]):
        for i in range(n):
            j = (i + 1) % n
            faces.append((a[i], a[j], b[j], b[i]))
    if cap_bottom:
        faces.append(tuple(reversed(index[0])))
    if cap_top:
        faces.append(tuple(index[-1]))
    return common.mesh(name, [p for ring in rings for p in ring], faces)


def _square(sx, sy, z, off=(0.0, 0.0), chamfer=0.0):
    ring = common.rect(sx, sy, off) if chamfer <= 0.0 else common.chamfered_rect(sx, sy, chamfer, off)
    return common.at(ring, z)


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
    """common.ngon at height z, by default turned so a flat, not a corner, faces -Y (the front)."""
    if phase is None:
        phase = -math.pi / 2.0 + math.pi / segments
    return common.at(common.ngon(segments, radius, phase), z)


def prism(name, radius, length, segments=6, radius2=None, origin=(0.0, 0.0, 0.0), cap_top=True, cap_bottom=False,
          phase=None):
    """A `segments`-sided prism (or frustum with radius2) standing base-up from `origin`: 2 triangles a side, and
    segments - 2 for each cap."""
    r2 = radius if radius2 is None else radius2
    obj = _mesh(name, [ngon_ring(radius, 0.0, segments, phase), ngon_ring(r2, length, segments, phase)], cap_bottom,
                cap_top)
    obj.location = origin
    return obj


def panel(name, centre, u, v):
    """One quad (2 triangles) at `centre` spanning +-u and +-v; it faces u x v. For glowing strips and windows laid
    just off a surface."""
    c = mathutils.Vector(centre)
    u = mathutils.Vector(u)
    v = mathutils.Vector(v)
    return common.mesh(name, [c + a * u + b * v for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1))], [(0, 1, 2, 3)])


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
    n = len(points)
    verts = [(x, y, 0.0) for x, y in points] + [(x * top_scale, y * top_scale, height) for x, y in points]
    faces = [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n) if i not in skip_sides]
    faces.append(tuple(range(n, 2 * n)))
    if cap_bottom:
        faces.append(tuple(reversed(range(n))))
    return common.mesh(name, verts, faces, origin)


def cone(name, radius, height, segments=6, origin=(0.0, 0.0, 0.0), phase=None):
    """A `segments`-sided cone to a point, no base: `segments` triangles."""
    verts = ngon_ring(radius, 0.0, segments, phase) + [(0.0, 0.0, height)]
    return common.mesh(name, verts, [(i, (i + 1) % segments, segments) for i in range(segments)], origin)


def disc(name, radius, segments, origin=(0.0, 0.0, 0.0), phase=None):
    """A flat, upward-facing regular polygon (segments - 2 triangles): the floor seen inside an open silo, so its
    single-sided walls do not show through when the hatch swings open."""
    return common.mesh(name, ngon_ring(radius, 0.0, segments, phase), [tuple(range(segments))], origin)
