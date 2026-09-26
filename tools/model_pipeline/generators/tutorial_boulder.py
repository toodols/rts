"""unit_defs `tutorial_boulder`: a massive neutral rock blocking a chokepoint on the tutorial map.

A craggy grey-brown pile of big angular chunks, with a few smaller rocks tumbled at its foot. About 44 studs along X,
36 along Z (Roblox; Blender Y) and 28 tall, the footprint centred on the origin and the base on the ground. No team
colour. Budget: 250 triangles (it is one of a handful on a map, not one of thousands of units).

The build scales a unit to fill its def's collider (build.py's fill_volume), never shrinking it; the size here is the
one the map was laid out for.
"""

import math
import random

import bmesh
import mathutils

from .shared import common
from .shared import palette

CATEGORY = "prop"
DEF = "tutorial_boulder"
SIZE = (44.0, 36.0, 28.0)  # Blender (x, y, z)


def lump(name, subdivisions, radii, centre, rng, rough, flatten=0.0):
    """An icosphere of the given radii at centre, each vertex pushed in or out along its direction by up to `rough`
    of its radius, and cut off flat at the ground (z = 0). With flatten, its top is squashed down that fraction
    toward a plateau, for a blockier, weathered crown."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    bmesh.ops.create_icosphere(bm, subdivisions=subdivisions, radius=1.0)
    # turned at random first, so no two chunks show the same facets
    turn = mathutils.Euler([rng.uniform(0.0, math.tau) for _ in range(3)]).to_matrix()
    for v in bm.verts:
        d = (turn @ v.co).normalized()
        k = 1.0 + rng.uniform(-rough, rough)
        x, y, z = d.x * radii[0] * k, d.y * radii[1] * k, d.z * radii[2] * k
        if flatten and d.z > 0.55:
            z -= (z - radii[2] * 0.55) * flatten
        v.co = (centre[0] + x, centre[1] + y, max(0.0, centre[2] + z))
    # the faces flattened onto the ground are never seen
    bm.normal_update()
    hidden = [f for f in bm.faces if all(v.co.z < 1e-4 for v in f.verts)]
    bmesh.ops.delete(bm, geom=hidden, context="FACES_ONLY")
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def generate(params):
    rng = random.Random(params.get("seed", 7))
    # a pile of big angular chunks (icosahedra, whose facets meet at hard edges), the tallest in the middle
    crags = [
        lump("core", 1, (14.0, 12.0, 15.0), (-2.0, 0.5, 11.0), rng, 0.22, flatten=0.3),
        lump("crag_w", 1, (10.0, 9.5, 9.0), (-11.0, -2.0, 6.0), rng, 0.22),
        lump("crag_e", 1, (11.0, 10.0, 10.5), (10.0, 1.5, 7.0), rng, 0.22),
        lump("crag_s", 1, (9.0, 7.5, 7.5), (1.0, -9.0, 4.5), rng, 0.2),
        lump("crag_n", 1, (9.5, 8.0, 8.0), (0.0, 9.5, 5.0), rng, 0.2),
        lump("crown", 1, (8.5, 7.0, 6.5), (2.5, -1.0, 19.5), rng, 0.25),
    ]
    rubble = [
        lump("rubble_1", 1, (4.2, 3.6, 3.2), (-19.0, -9.5, 1.0), rng, 0.2),
        lump("rubble_2", 1, (3.4, 3.0, 2.6), (18.5, 10.5, 0.8), rng, 0.2),
        lump("rubble_3", 1, (3.2, 3.6, 2.6), (9.0, -13.5, 0.6), rng, 0.2),
        lump("rubble_4", 1, (2.8, 2.4, 2.2), (-13.0, 12.5, 0.5), rng, 0.2),
        lump("rubble_5", 1, (2.2, 2.0, 1.8), (-6.0, -14.5, 0.3), rng, 0.2),
    ]
    for obj in crags:
        common.paint(obj, palette.BOULDER)
    for obj in rubble + crags[1::3]:
        obj.data.materials.clear()
        common.paint(obj, palette.BOULDER_RUBBLE)
    objs = crags + rubble

    # stretch to the size the map expects, the footprint centred on the origin and the base on the ground
    lo = [math.inf] * 3
    hi = [-math.inf] * 3
    for obj in objs:
        for v in obj.data.vertices:
            for i in range(3):
                lo[i] = min(lo[i], v.co[i])
                hi[i] = max(hi[i], v.co[i])
    centre = ((lo[0] + hi[0]) / 2, (lo[1] + hi[1]) / 2)
    scale = [SIZE[i] / (hi[i] - lo[i]) for i in range(3)]
    for obj in objs:
        for v in obj.data.vertices:
            v.co = (
                (v.co.x - centre[0]) * scale[0],
                (v.co.y - centre[1]) * scale[1],
                (v.co.z - lo[2]) * scale[2],
            )
    return objs
