"""Shared shapes and materials for the T1 aircraft (unit_defs/air_t1.luau), also used by t3_common.py.

Every model is held to 100 triangles, so these build faceted low-poly shapes vertex by vertex and leave off
faces nothing can see (Roblox culls back faces, so every face that stays must look outward):

- loft(): a hull skinned through cross-section rings along Y (nose to tail); a 0-size ring is a sharp point.
- bipyramid(): a flat panel thick in the middle and knife-edged all round, for wings and tailplanes.
- tetra() / poly(): fins, canopies and anything else built straight from points.
- plate(): one quad looking one way, for glows, intakes and rotor blades.
- block() / beam() / drop_faces(): tapered boxes, upright or between two points, minus their hidden faces.
- flat(): flat shading and UVs; no bevel, which would multiply the triangles.

Everything is built in studs, Blender Z up, facing -Y (the nose points -Y).
"""

import math

import bmesh
import bpy
import mathutils

from . import common

GLOW_COLOR = (1.0, 0.55, 0.16, 1.0)  # jet exhaust amber-orange
GLASS_COLOR = (0.10, 0.16, 0.22, 1.0)  # dark tinted canopy glass
HIVIS_COLOR = (0.98, 0.80, 0.10, 1.0)  # high-vis nanolathe yellow (not team tinted)
NANO_COLOR = (0.35, 0.95, 0.75, 1.0)  # nanolathe emitter, as on the construction turret


def rgb(r, g, b):
    return (r / 255.0, g / 255.0, b / 255.0, 1.0)


def accent_mat(obj, def_name, color):
    common.apply_material(obj, f"air_accent_{def_name}", color, roughness=0.4, metallic=0.15)


def glow_mat(obj, color=GLOW_COLOR, name="air_glow_engine"):
    common.apply_material(obj, name, color, roughness=0.2, metallic=0.0, emission=1.0)


def glass_mat(obj):
    common.apply_material(obj, "air_glass", GLASS_COLOR, roughness=0.12, metallic=0.3)


def hivis_mat(obj):
    common.apply_material(obj, "air_hivis", HIVIS_COLOR, roughness=0.38, metallic=0.1)


def nano_mat(obj):
    common.apply_material(obj, "air_nano_glow", NANO_COLOR, roughness=0.15, metallic=0.0, emission=1.0)


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
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    rings = []
    for sec in sections:
        y, cz, w, h = sec[:4]
        cx = sec[4] if len(sec) > 4 else 0.0
        if w < 1e-5 or h < 1e-5:
            rings.append([bm.verts.new((cx, y, cz))])
        else:
            rings.append([bm.verts.new(p) for p in _ring(cx, y, cz, w, h, sides, square, rot)])
    for a, b in zip(rings, rings[1:]):
        if len(a) == 1 and len(b) == 1:
            continue
        if len(a) == 1:
            for i in range(len(b)):
                bm.faces.new((a[0], b[i], b[(i + 1) % len(b)]))
        elif len(b) == 1:
            for i in range(len(a)):
                bm.faces.new((a[i], a[(i + 1) % len(a)], b[0]))
        else:
            for i in range(len(a)):
                j = (i + 1) % len(a)
                bm.faces.new((a[i], a[j], b[j], b[i]))
    if len(rings[0]) > 2:
        bm.faces.new(rings[0])
    if len(rings[-1]) > 2:
        bm.faces.new(rings[-1])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def drop_faces(obj, indices):
    """Deletes faces by index (e.g. a box's bottom where it sits on something), saving their triangles."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.faces[i] for i in indices], context="FACES_ONLY")
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def block(name, bx, by, h, tx=None, ty=None, top_offset=(0.0, 0.0), origin=(0.0, 0.0, 0.0), open_bottom=False):
    """common.tapered_box (a plain box when tx/ty are left out), optionally without its bottom face."""
    obj = common.tapered_box(name, bx, by, h, bx if tx is None else tx, by if ty is None else ty,
                             top_offset=top_offset, origin=origin)
    if open_bottom:
        drop_faces(obj, [0])
    return obj


def beam(name, a, b, sx, sy, top_scale=1.0, roll=0.0, open_start=False):
    """A box of cross-section sx by sy from point a to point b (its top face scaled by top_scale). The
    cross-section's X is kept as horizontal as the direction allows; `roll` turns it about the axis.
    `open_start` leaves off the end face at a, for a beam whose start is buried in something."""
    a, b = mathutils.Vector(a), mathutils.Vector(b)
    d = b - a
    length = d.length
    obj = block(name, sx, sy, length, sx * top_scale, sy * top_scale, open_bottom=open_start)
    quat = d.normalized().to_track_quat("Z", "Y")
    if roll:
        quat = quat @ mathutils.Quaternion((0.0, 0.0, 1.0), roll)
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = quat
    obj.location = a
    return obj


def check_fit(objects, radius, height, label):
    """Prints how far the model reaches against its collider cylinder, so a build log shows it fits. Measured
    after the recentring build.py does on the first object's bounds."""
    bpy.context.view_layer.update()
    corners = [objects[0].matrix_world @ mathutils.Vector(c) for c in objects[0].bound_box]
    ox = (min(c.x for c in corners) + max(c.x for c in corners)) / 2
    oy = (min(c.y for c in corners) + max(c.y for c in corners)) / 2
    reach = 0.0
    lo, hi = 1e9, -1e9
    tris = 0
    for obj in objects:
        m = obj.matrix_world
        tris += sum(len(p.vertices) - 2 for p in obj.data.polygons)
        for v in obj.data.vertices:
            w = m @ v.co
            reach = max(reach, math.hypot(w.x - ox, w.y - oy))
            lo, hi = min(lo, w.z), max(hi, w.z)
    ok = reach <= radius + 1e-3 and lo >= -1e-3 and hi <= height + 1e-3
    print(f"fit {label}: reach {reach:.2f}/{radius:.2f}, z {lo:.2f}..{hi:.2f}/{height:.2f} {'OK' if ok else 'OVER'}, "
          f"{tris} tris, offset ({ox:.3f}, {oy:.3f})")


def poly(name, verts, faces, facing=None):
    """A mesh straight from vertices and faces (index tuples), for low-poly shapes built vertex by vertex.
    Normals are recalculated outward; an open shell (its hidden side sunk into another part) is fine. A lone
    face has no outside, so `facing` (a direction) says which way it should look."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    vs = [bm.verts.new(v) for v in verts]
    for f in faces:
        bm.faces.new([vs[i] for i in f])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
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


def flat(objects):
    """Flat shading and UVs, no bevel: for low-poly faceted parts whose facets are the look."""
    for obj in objects:
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.shade_flat()
        common.smart_uv(obj)
    bpy.ops.object.select_all(action="DESELECT")
    return objects


def plate(name, center, half_u, half_v, facing):
    """A single rectangular face centred on `center`, spanning +-half_u and +-half_v (3D vectors), looking
    along `facing`: exhaust glows, intake faces, vents, hatches laid on a surface. 2 triangles."""
    c, u, v = mathutils.Vector(center), mathutils.Vector(half_u), mathutils.Vector(half_v)
    pts = [tuple(c - u - v), tuple(c + u - v), tuple(c + u + v), tuple(c - u + v)]
    return poly(name, pts, [(0, 1, 2, 3)], facing=facing)
