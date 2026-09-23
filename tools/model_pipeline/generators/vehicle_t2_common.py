"""Shared pieces for the tier-two vehicles (src/shared/unit_defs/vehicle_t2.luau): the Advanced Construction
Vehicle, Mantis, its Drone, Quaker, Negotiator, Tiger and Poison Arrow.

Every vehicle faces Blender -Y (Roblox +Z) with its origin on the ground at the centre of its collider. A
collider capsule(w, h, l) in elmos is a cylinder of radius max(w, l) / 22 studs and height h / 11 studs, and the
whole model -- turret barrels at any yaw included -- stays inside it; `collider()` returns those two numbers.

Each model has a hard budget of 100 triangles in all, so these builders make flat-shaded, unbevelled meshes
directly and let a caller leave out the faces nobody sees (undersides, faces buried in another piece): a box
costs 2 triangles a face, so a hull without its bottom is 10, a barrel is a 4-sided rod with a front cap (10).
Faces are wound outward from the piece's own centre, which is right for the convex shapes all of these are.

Cortex's look, as in BAR: squat, armored hulls with sloped glacis plates, armor over the tracks, and the team
accent on the big top panels so a unit's side reads from the RTS camera.
"""

import math

import bmesh
from mathutils import Vector

from . import common


def collider(w, h, l):
    """(radius, height) in studs of a def's capsule(w, h, l)."""
    return max(w, l) / 22.0, h / 11.0


def rgb(r, g, b):
    return (r / 255.0, g / 255.0, b / 255.0, 1.0)


GLOW_COLOR = (1.0, 0.78, 0.35, 1.0)  # warm headlight amber
NANO_COLOR = (0.35, 0.95, 0.75, 1.0)  # nanolathe green-cyan, as on the construction turret
HIVIS_COLOR = (0.98, 0.80, 0.10, 1.0)  # builder high-vis yellow, never team tinted


class Mats:
    """Material setters for one unit: body/trim are the shared palette, `accent` the team-tinted colour."""

    def __init__(self, unit, accent_color):
        self.unit = unit
        self.accent_color = accent_color

    def body(self, obj):
        common.body_mat(obj)
        return obj

    def trim(self, obj):
        common.trim_mat(obj)
        return obj

    def accent(self, obj):
        common.apply_material(obj, f"veh_t2_accent_{self.unit}", self.accent_color, roughness=0.4, metallic=0.15)
        return obj

    def glow(self, obj, color=GLOW_COLOR, name="glow"):
        common.apply_material(obj, f"veh_t2_{name}_{self.unit}", color, roughness=0.2, metallic=0.0, emission=1.0)
        return obj

    def hivis(self, obj):
        common.apply_material(obj, "veh_t2_hivis", HIVIS_COLOR, roughness=0.4, metallic=0.1)
        return obj


def mesh(name, verts, faces, outward_from=None, up=None):
    """An object from raw vertices and faces (index tuples). Each face is wound to face away from
    `outward_from` (default: the centroid of all the vertices), or along `up` when given (single decals)."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    bv = [bm.verts.new(p) for p in verts]
    if outward_from is not None:
        centre = Vector(outward_from)
    else:
        centre = sum((Vector(p) for p in verts), Vector()) / len(verts)
    for f in faces:
        face = bm.faces.new([bv[i] for i in f])
        face.normal_update()
        want = Vector(up) if up is not None else face.calc_center_median() - centre
        if face.normal.dot(want) < 0.0:
            face.normal_flip()
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def block(name, sx, sy, sz, origin=(0.0, 0.0, 0.0), top=None, top_offset=(0.0, 0.0), drop=("bottom",)):
    """A box (or, with top=(tx, ty), a tapered box whose top can shift by top_offset) standing on `origin`,
    centred on it in X/Y. `drop` names faces to leave out: bottom (by default), top, front (-Y), back, left
    (-X), right."""
    bx, by = sx / 2.0, sy / 2.0
    tx, ty = (bx, by) if top is None else (top[0] / 2.0, top[1] / 2.0)
    ox, oy = top_offset
    x0, y0, z0 = origin
    verts = [
        (x0 - bx, y0 - by, z0), (x0 + bx, y0 - by, z0), (x0 + bx, y0 + by, z0), (x0 - bx, y0 + by, z0),
        (x0 + ox - tx, y0 + oy - ty, z0 + sz), (x0 + ox + tx, y0 + oy - ty, z0 + sz),
        (x0 + ox + tx, y0 + oy + ty, z0 + sz), (x0 + ox - tx, y0 + oy + ty, z0 + sz),
    ]
    named = {
        "bottom": (0, 1, 2, 3), "top": (4, 5, 6, 7), "front": (0, 1, 5, 4),
        "right": (1, 2, 6, 5), "back": (2, 3, 7, 6), "left": (3, 0, 4, 7),
    }
    return mesh(name, verts, [f for k, f in named.items() if k not in drop])


def prism_x(name, profile_yz, width, x=0.0, drop_bottom=True, caps=("-x", "+x")):
    """A side-profile polygon (points (y, z) in order round it, -Y is the front) extruded `width` across X,
    centred on x. Leaves out the flat underside when drop_bottom, and whichever end caps are not in `caps`."""
    n = len(profile_yz)
    hw = width / 2.0
    verts = [(x - hw, y, z) for y, z in profile_yz] + [(x + hw, y, z) for y, z in profile_yz]
    zmin = min(z for _, z in profile_yz)
    faces = []
    for i in range(n):
        j = (i + 1) % n
        if drop_bottom and abs(profile_yz[i][1] - zmin) < 1e-6 and abs(profile_yz[j][1] - zmin) < 1e-6:
            continue
        faces.append((i, j, n + j, n + i))
    if "-x" in caps:
        faces.append(tuple(range(n)))
    if "+x" in caps:
        faces.append(tuple(range(n, 2 * n)))
    return mesh(name, verts, faces)


def loft(name, sections, x=0.0, drop=("bottom",)):
    """A hull lofted through trapezoid cross-sections along Y, front (-Y) first, each (y, half_width_bottom,
    half_width_top, z_bottom, z_top). `drop` can leave out the bottom, top, left and right sides and the
    front and back end caps."""
    verts = []
    for y, wb, wt, zb, zt in sections:
        verts += [(x - wb, y, zb), (x + wb, y, zb), (x + wt, y, zt), (x - wt, y, zt)]
    faces = []
    sides = {"bottom": (0, 1), "right": (1, 2), "top": (2, 3), "left": (3, 0)}
    for s in range(len(sections) - 1):
        a, b = 4 * s, 4 * (s + 1)
        for key, (i, j) in sides.items():
            if key not in drop:
                faces.append((a + i, a + j, b + j, b + i))
    if "front" not in drop:
        faces.append((0, 1, 2, 3))
    if "back" not in drop:
        last = 4 * (len(sections) - 1)
        faces.append((last, last + 1, last + 2, last + 3))
    return mesh(name, verts, faces)


def direction(pitch, yaw=0.0):
    """The unit vector toward the front (-Y), raised `pitch` degrees and turned `yaw` about Z (toward +X)."""
    p, w = math.radians(pitch), math.radians(yaw)
    d = Vector((0.0, -math.cos(p), math.sin(p)))
    return Vector((d.x * math.cos(w) - d.y * math.sin(w), d.x * math.sin(w) + d.y * math.cos(w), d.z))


def rod(name, radius, length, start, pitch=0.0, yaw=0.0, sides=4, front_cap=True, back_cap=False, radius2=None,
        roll=45.0):
    """An n-sided rod (a barrel, a boom, a mast) running `length` from `start` along direction(pitch, yaw);
    pitch=90 stands it straight up. `radius2` tapers it toward the far end. Returns (obj, end_point)."""
    d = direction(pitch, yaw)
    ref = Vector((0.0, 0.0, 1.0)) if abs(d.z) < 0.9 else Vector((1.0, 0.0, 0.0))
    u = d.cross(ref).normalized()
    w = d.cross(u).normalized()
    s = Vector(start)
    e = s + d * length
    r2 = radius if radius2 is None else radius2
    verts = []
    for centre, r in ((s, radius), (e, r2)):
        for k in range(sides):
            a = math.radians(roll) + 2.0 * math.pi * k / sides
            verts.append(tuple(centre + (u * math.cos(a) + w * math.sin(a)) * r))
    faces = [(k, (k + 1) % sides, sides + (k + 1) % sides, sides + k) for k in range(sides)]
    if back_cap:
        faces.append(tuple(range(sides)))
    if front_cap:
        faces.append(tuple(range(sides, 2 * sides)))
    obj = mesh(name, verts, faces, outward_from=tuple((s + e) / 2.0))
    return obj, tuple(e)


def frustum(name, r1, r2, h, origin=(0.0, 0.0, 0.0), sides=6, bottom=False, top=True, turn=0.0):
    """An n-sided prism/frustum standing on `origin`, radius r1 at the bottom and r2 at the top, turned `turn`
    degrees about Z. No underside unless `bottom`."""
    x0, y0, z0 = origin
    verts = []
    for z, r in ((z0, r1), (z0 + h, r2)):
        for k in range(sides):
            a = math.radians(turn) + 2.0 * math.pi * k / sides
            verts.append((x0 + math.cos(a) * r, y0 + math.sin(a) * r, z))
    faces = [(k, (k + 1) % sides, sides + (k + 1) % sides, sides + k) for k in range(sides)]
    if bottom:
        faces.append(tuple(range(sides)))
    if top:
        faces.append(tuple(range(sides, 2 * sides)))
    return mesh(name, verts, faces, outward_from=(x0, y0, z0 + h / 2.0))


def decal(name, corners, up=(0.0, 0.0, 1.0)):
    """A single flat polygon laid just over a surface -- a painted stripe, a glowing light strip -- at n-2
    triangles, facing `up`."""
    return mesh(name, corners, [tuple(range(len(corners)))], up=up)


def track(name, x, length, height, width, y=0.0, nose=0.45):
    """A track run in side profile -- flat on the ground, sloped up to the idler and sprocket, flat on top --
    with no underside and only its outer end cap: 8 triangles."""
    hl = length / 2.0
    e = height * nose
    profile = [(y - hl + e, 0.0), (y + hl - e, 0.0), (y + hl, height), (y - hl, height)]
    return prism_x(name, profile, width, x, caps=("+x",) if x > 0 else ("-x",))


def axle(name, hub, radius, half_width, sides=6):
    """A pair of wheels on one axle as a single n-sided drum running across the vehicle along X: its two end
    caps are the wheel faces and the drum between them is the tread, most of it hidden under the bed (20
    triangles for a hexagon). Its vertices are built about the hub, and its origin is the hub, so it can roll
    as a kind="wheel" piece pivoting on it."""
    verts = []
    for x in (-half_width, half_width):
        for k in range(sides):
            a = 2.0 * math.pi * k / sides
            verts.append((x, radius * math.cos(a), radius * math.sin(a)))
    faces = [(k, (k + 1) % sides, sides + (k + 1) % sides, sides + k) for k in range(sides)]
    faces += [tuple(range(sides)), tuple(range(sides, 2 * sides))]
    obj = mesh(name, verts, faces, outward_from=(0.0, 0.0, 0.0))
    obj.location = hub
    return obj


def triangles(objects):
    return sum(len(p.vertices) - 2 for o in objects for p in o.data.polygons)


def check_fit(objects, radius, height, label):
    """Prints the triangle total and how far the model reaches against its collider cylinder (a turning piece
    at its worst yaw), so a build log shows a violation."""
    import bpy

    bpy.context.view_layer.update()
    far, top, low = 0.0, 0.0, 0.0
    pivots = {o["art_group"]: o.matrix_world.translation.copy() for o in objects if o.get("art_pivot")}
    kinds = {o["art_group"]: o.get("art_kind") for o in objects if o.get("art_pivot")}
    for obj in objects:
        group = obj.get("art_group")
        pivot = pivots.get(group)
        for vert in obj.data.vertices:
            w = obj.matrix_world @ vert.co
            if pivot is not None and kinds.get(group) == "wheel":
                # rolls about X through its hub: every point sweeps a circle in Y/Z about the hub
                r = math.hypot(w.y - pivot.y, w.z - pivot.z)
                reach = math.hypot(w.x, abs(pivot.y) + r)
                top = max(top, pivot.z + r)
                low = min(low, pivot.z - r)
            elif pivot is not None:
                reach = math.hypot(pivot.x, pivot.y) + math.hypot(w.x - pivot.x, w.y - pivot.y)
            else:
                reach = math.hypot(w.x, w.y)
            far = max(far, reach)
            top = max(top, w.z)
            low = min(low, w.z)
    tris = triangles(objects)
    ok = far <= radius + 1e-3 and top <= height + 1e-3 and low >= -1e-3 and tris <= 100
    print(f"fit {label}: {tris} tris  reach {far:.3f}/{radius:.3f}  top {top:.3f}/{height:.3f}  "
          f"bottom {low:.3f}  {'OK' if ok else 'OUTSIDE'}")
