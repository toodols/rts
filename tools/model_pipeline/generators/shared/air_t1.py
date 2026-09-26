"""Shared shapes and materials for the T1 aircraft (unit_defs/air_t1.luau), also used by shared/t3.py.

Every model is held to 100 triangles, so these build faceted low-poly shapes vertex by vertex and leave off
faces nothing can see (Roblox culls back faces, so every face that stays must look outward):

- loft(): a hull skinned through cross-section rings along Y (nose to tail); a 0-size ring is a sharp point.
- bipyramid(): a flat panel thick in the middle and knife-edged all round, for wings and tailplanes.
- tetra() / poly(): fins, canopies and anything else built straight from points.
- plate(): one quad looking one way, for glows, intakes and rotor blades.
- beam(): a tapered box between two points, minus its buried start if asked.

Everything is built in studs, Blender Z up, facing -Y (the nose points -Y).
"""

import math

import bmesh
import mathutils

from . import common
from . import palette


def glass_mat(obj):
    common.paint(obj, palette.CANOPY_GLASS)


def _ring(cx, y, cz, w, h, sides, square, rot):
    pts = []
    e = 2.0 / square
    for i in range(sides):
        a = rot + 2.0 * math.pi * i / sides
        c, s = math.cos(a), math.sin(a)
        x = math.copysign(abs(c) ** e, c) * w
        z = math.copysign(abs(s) ** e, s) * h
        pts.append((cx + x, y, cz + z))
    return pts


def loft(name, sections, sides=8, square=2.0, rot=None):
    """A closed hull through `sections`, each (y, cz, w, h) or (y, cz, w, h, cx): a ring of `sides` points
    centred on (cx, y, cz) with half-width w (X) and half-height h (Z). `square` > 2 squares the ring off
    (4 is a rounded box). A section with w or h of 0 is a single point: a sharp nose or tail."""
    if rot is None:
        rot = math.pi / sides  # flats, not corners, top/bottom/sides
    points = []
    rings = []
    for sec in sections:
        y, cz, w, h = sec[:4]
        cx = sec[4] if len(sec) > 4 else 0.0
        ring = [(cx, y, cz)] if w < 1e-5 or h < 1e-5 else _ring(cx, y, cz, w, h, sides, square, rot)
        rings.append(list(range(len(points), len(points) + len(ring))))
        points += ring
    faces = []
    for a, b in zip(rings, rings[1:]):
        if len(a) == 1 and len(b) == 1:
            continue
        if len(a) == 1:
            faces += [(a[0], b[i], b[(i + 1) % len(b)]) for i in range(len(b))]
        elif len(b) == 1:
            faces += [(a[i], a[(i + 1) % len(a)], b[0]) for i in range(len(a))]
        else:
            faces += [(a[i], a[(i + 1) % len(a)], b[(i + 1) % len(a)], b[i]) for i in range(len(a))]
    if len(rings[0]) > 2:
        faces.append(tuple(rings[0]))
    if len(rings[-1]) > 2:
        faces.append(tuple(rings[-1]))
    return common.mesh(name, points, faces, recalc_normals=True)


def beam(name, a, b, sx, sy, top_scale=1.0, roll=0.0, open_start=False):
    """A box of cross-section sx by sy from point a to point b (its top face scaled by top_scale). The
    cross-section's X is kept as horizontal as the direction allows; `roll` turns it about the axis.
    `open_start` leaves off the end face at a, for a beam whose start is buried in something."""
    a, b = mathutils.Vector(a), mathutils.Vector(b)
    d = b - a
    length = d.length
    obj = common.block(name, sx, sy, length, top=(sx * top_scale, sy * top_scale))
    if open_start:
        common.drop_bottom(obj)
    quat = d.normalized().to_track_quat("Z", "Y")
    if roll:
        quat = quat @ mathutils.Quaternion((0.0, 0.0, 1.0), roll)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = quat
    obj.location = a
    return obj


def poly(name, verts, faces, facing=None):
    """A mesh straight from vertices and faces (index tuples), for low-poly shapes built vertex by vertex.
    Normals are recalculated outward; an open shell (its hidden side sunk into another part) is fine. A lone
    face has no outside, so `facing` (a direction) says which way it should look."""
    obj = common.mesh(name, verts, faces, recalc_normals=True)
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    if facing is None and len(bm.faces) > 1:
        # every shape built this way is convex, open or not: point each face away from the middle, which an
        # open shell's recalc can get backwards (and Roblox culls back faces)
        bm.normal_update()
        mid = sum((v.co for v in bm.verts), mathutils.Vector()) / len(bm.verts)
        flip = [f for f in bm.faces if f.normal.dot(f.calc_center_median() - mid) < 0.0]
        if flip:
            bmesh.ops.reverse_faces(bm, faces=flip)
    if facing is not None:
        bm.normal_update()
        want = mathutils.Vector(facing)
        flip = [f for f in bm.faces if f.normal.dot(want) < 0.0]
        if flip:
            bmesh.ops.reverse_faces(bm, faces=flip)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def bipyramid(name, outline, top, bottom):
    """A flat panel as two fans: every edge of `outline` (a loop of 3D points) joined to a `top` and a
    `bottom` apex, so it is thick in the middle and knife-edged all round: 2 triangles per outline point."""
    n = len(outline)
    verts = list(outline) + [top, bottom]
    faces = []
    for i in range(n):
        j = (i + 1) % n
        faces.append((i, j, n))
        faces.append((j, i, n + 1))
    return poly(name, verts, faces)


def tetra(name, a, b, c, d):
    """Four points, four triangles: the cheapest closed solid, for fins, nozzles and glints."""
    return poly(name, [a, b, c, d], [(0, 1, 2), (0, 3, 1), (1, 3, 2), (0, 2, 3)])


def plate(name, center, half_u, half_v, facing):
    """A single rectangular face centred on `center`, spanning +-half_u and +-half_v (3D vectors), looking
    along `facing`: exhaust glows, intake faces, vents, hatches laid on a surface. 2 triangles."""
    c, u, v = mathutils.Vector(center), mathutils.Vector(half_u), mathutils.Vector(half_v)
    pts = [tuple(c - u - v), tuple(c + u - v), tuple(c + u + v), tuple(c - u + v)]
    return poly(name, pts, [(0, 1, 2, 3)], facing=facing)
