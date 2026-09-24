"""Shared shapes for the reclaimables (tree, shrub, rock): the rocks and trees strewn over a map by the thousand.

They are not dressed by the client like a unit's art: the server clones one MeshPart per mesh into each reclaimable's
model (src/server/instances.luau), scaled to fill its collider, so their art modules go to src/shared/reclaimable_art/
(build with -LuauOut), never src/shared/art/. What matters is how few MeshParts one takes, not only how few triangles:
every material is a MeshPart of its own, so each keeps to one or two, and nothing moves, so all of it is one piece.
"""

import math

import bmesh
import mathutils

from . import common


def cone(name, radius, height, z=0.0, segments=6, turn=0.0, base=True):
    """A `segments`-sided cone standing on its base at height z, turned `turn` radians about the vertical: a tier of a
    fir's crown. Without `base`, its underside is left open, for a tier whose underside the one below hides."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    ring = [
        bm.verts.new((radius * math.cos(turn + math.tau * i / segments), radius * math.sin(turn + math.tau * i / segments), z))
        for i in range(segments)
    ]
    apex = bm.verts.new((0.0, 0.0, z + height))
    for i in range(segments):
        bm.faces.new((ring[i], ring[(i + 1) % segments], apex))
    if base:
        bm.faces.new(list(reversed(ring)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def frustum(name, radius, top_radius, height, segments=6):
    """An open `segments`-sided frustum standing on the ground, no caps: a trunk, whose foot is in the ground and whose
    top is inside the crown."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    low = [bm.verts.new((radius * math.cos(math.tau * i / segments), radius * math.sin(math.tau * i / segments), 0.0)) for i in range(segments)]
    high = [
        bm.verts.new((top_radius * math.cos(math.tau * i / segments), top_radius * math.sin(math.tau * i / segments), height))
        for i in range(segments)
    ]
    for i in range(segments):
        j = (i + 1) % segments
        bm.faces.new((low[i], low[j], high[j], high[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def lump(name, radii, centre, rng, rough, flatten=0.0):
    """An icosahedron (20 faces, hard-edged) of the given radii at centre, each vertex pushed in or out by up to `rough`
    of its radius, and cut off flat at the ground, where the faces that end up lying on it are dropped. With flatten,
    its top is squashed that fraction toward a plateau."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=1, radius=1.0)
    # turned at random first, so no two show the same facets
    turn = mathutils.Euler([rng.uniform(0.0, math.tau) for _ in range(3)]).to_matrix()
    for v in bm.verts:
        d = (turn @ v.co).normalized()
        k = 1.0 + rng.uniform(-rough, rough)
        x, y, z = d.x * radii[0] * k, d.y * radii[1] * k, d.z * radii[2] * k
        if flatten and d.z > 0.5:
            z -= (z - radii[2] * 0.5) * flatten
        v.co = (centre[0] + x, centre[1] + y, max(0.0, centre[2] + z))
    bm.normal_update()
    hidden = [f for f in bm.faces if all(v.co.z < 1e-4 for v in f.verts)]
    bmesh.ops.delete(bm, geom=hidden, context="FACES_ONLY")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.to_mesh(obj.data)
    bm.free()
    return obj
