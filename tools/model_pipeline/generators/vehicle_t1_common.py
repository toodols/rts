"""Shared parts for the Vehicle Lab's first tier (unit_defs/vehicle_t1.luau): construction_vehicle, incisor,
lasher, rascal, wolverine, brute.

Budget: at most 100 triangles a model (the whole of it), so every shape here is a handful of flat faces and
nothing the camera cannot see is built. The pieces are prisms extruded along X from a side profile (hulls,
turrets, track runs, wheels), and tapered blocks that can leave out any of their six faces; floor faces,
faces buried in a hull and the inner caps of wheels are left out. No bevels, no spheres: a glow is an
8-triangle diamond or a 4-triangle spike.

The unit faces Blender -Y (Roblox +Z). Origin = ground, centred on the footprint.
"""

import math

import bmesh
import bpy

from . import common

GLOW_COLOR = (1.0, 0.72, 0.15, 1.0)  # warm amber muzzle/lamp, as on the towers
LASER_COLOR = (1.0, 0.12, 0.08, 1.0)  # red laser lens
NANO_COLOR = (0.35, 0.95, 0.75, 1.0)  # nanolathe green-cyan, as on the construction turret
HIVIS_COLOR = (0.95, 0.78, 0.12, 1.0)  # builder yellow, not team-tinted


def rgb(r, g, b):
    return (r / 255.0, g / 255.0, b / 255.0, 1.0)


def accent_mat(obj, name, color):
    """Team-coloured paint. `name` is the def, so every model's material is its own."""
    common.apply_material(obj, f"veh_t1_accent_{name}", color, roughness=0.4, metallic=0.1)


def glow_mat(obj, name, color=GLOW_COLOR):
    common.apply_material(obj, f"veh_t1_glow_{name}", color, roughness=0.2, metallic=0.0, emission=1.0)


def hivis_mat(obj, name):
    common.apply_material(obj, f"veh_t1_hivis_{name}", HIVIS_COLOR, roughness=0.4, metallic=0.1)


def dark_mat(obj):
    common.trim_mat(obj)


def body_mat(obj):
    common.body_mat(obj)


def paint(objs, mat, *args):
    for o in objs:
        mat(o, *args)
    return objs


def _object(name, verts, faces, origin):
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    vs = [bm.verts.new(v) for v in verts]
    for f in faces:
        bm.faces.new([vs[i] for i in f])
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def prism(name, profile, width_bottom, width_top=None, origin=(0.0, 0.0, 0.0), caps="both", open_bottom=True):
    """A prism extruded along X from a side profile [(y, z), ...], centred on x = 0. Its half-width runs from
    width_bottom/2 at the profile's lowest z to width_top/2 at its highest, so the flanks can slope. `caps` is
    which ends are closed: "both", "left" (-X), "right" (+X) or "none"; `open_bottom` leaves out every edge face
    lying flat along the profile's lowest z (the floor)."""
    if width_top is None:
        width_top = width_bottom
    pts = list(profile)
    area = sum(pts[i][0] * pts[(i + 1) % len(pts)][1] - pts[(i + 1) % len(pts)][0] * pts[i][1] for i in range(len(pts)))
    if area < 0:
        pts.reverse()  # counter-clockwise in (y, z), so faces below come out facing outward
    zs = [p[1] for p in pts]
    z0, z1 = min(zs), max(zs)

    def half(z):
        t = 0.0 if z1 - z0 < 1e-9 else (z - z0) / (z1 - z0)
        return (width_bottom + (width_top - width_bottom) * t) / 2.0

    n = len(pts)
    verts = [(-half(z), y, z) for y, z in pts] + [(half(z), y, z) for y, z in pts]
    faces = []
    if caps in ("both", "right"):
        faces.append([n + i for i in range(n)])
    if caps in ("both", "left"):
        faces.append(list(reversed(range(n))))
    for i in range(n):
        j = (i + 1) % n
        if open_bottom and abs(pts[i][1] - z0) < 1e-6 and abs(pts[j][1] - z0) < 1e-6:
            continue
        faces.append([i, j, n + j, n + i])
    return _object(name, verts, faces, origin)


def block(name, sx, sy, sz, top_x=None, top_y=None, top_offset=(0.0, 0.0), origin=(0.0, 0.0, 0.0), skip=("bottom",)):
    """A box (or, with top_x/top_y/top_offset, a tapered block) standing base-up from `origin`, with any of its
    faces left out: skip holds any of "bottom", "top", "front" (-Y), "back" (+Y), "left" (-X), "right" (+X)."""
    top_x = sx if top_x is None else top_x
    top_y = sy if top_y is None else top_y
    bx, by, tx, ty = sx / 2.0, sy / 2.0, top_x / 2.0, top_y / 2.0
    ox, oy = top_offset
    verts = [
        (-bx, -by, 0.0), (bx, -by, 0.0), (bx, by, 0.0), (-bx, by, 0.0),
        (ox - tx, oy - ty, sz), (ox + tx, oy - ty, sz), (ox + tx, oy + ty, sz), (ox - tx, oy + ty, sz),
    ]
    all_faces = {
        "bottom": [3, 2, 1, 0],
        "top": [4, 5, 6, 7],
        "front": [0, 1, 5, 4],
        "right": [1, 2, 6, 5],
        "back": [2, 3, 7, 6],
        "left": [3, 0, 4, 7],
    }
    faces = [f for k, f in all_faces.items() if k not in skip]
    return _object(name, verts, faces, origin)


def hex_wheel(name, radius, width, center, outer_side):
    """A six-sided wheel on an axle along X, built about its hub so the object's origin is `center` (a rolling
    wheel's pivot). All six tread faces are kept, since each comes round to the top as it rolls, and only the
    outer cap (outer_side = -1 or +1): the inner one faces the body at every angle. 16 triangles. Flat side down
    at rest, its flats sit radius * sin(60) from the hub, so an axle at wheel_axle_z(radius) puts it on the
    ground, and that is its rolling radius."""
    profile = [(radius * math.cos(math.radians(60 * k)), radius * math.sin(math.radians(60 * k))) for k in range(6)]
    caps = "right" if outer_side > 0 else "left"
    return prism(name, profile, width, origin=center, caps=caps, open_bottom=False)


def rolling_wheels(prefix, radius, width, x, ys, mat):
    """Four (or more) hex wheels at (+-x, y) for each y in ys, each its own rolling piece "wheel_<f|b><l|r>"
    (front is the lowest y) pivoting on its hub. `mat(obj)` paints each. Returns the objects."""
    axle_z = wheel_axle_z(radius)
    wheels = []
    for i, wy in enumerate(sorted(ys)):
        fb = "f" if i == 0 else ("b" if i == len(ys) - 1 else f"m{i}")
        for sx, lr in ((-1.0, "l"), (1.0, "r")):
            w = hex_wheel(f"{prefix}_{fb}{lr}", radius, width, (sx * x, wy, axle_z), sx)
            mat(w)
            common.art_group(w, f"wheel_{fb}{lr}", pivot=True, kind="wheel", axis=(1.0, 0.0, 0.0), radius=axle_z)
            wheels.append(w)
    return wheels


def pyramid_up(name, sx, sy, height, apex=(0.0, 0.0), origin=(0.0, 0.0, 0.0)):
    """A four-sided pyramid standing on a (sx, sy) rectangle with no base, its apex offset by `apex`: 4 triangles."""
    bx, by = sx / 2.0, sy / 2.0
    verts = [(-bx, -by, 0.0), (bx, -by, 0.0), (bx, by, 0.0), (-bx, by, 0.0), (apex[0], apex[1], height)]
    faces = [[0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4]]
    return _object(name, verts, faces, origin)


def wheel_axle_z(radius):
    return radius * math.sin(math.radians(60))


def diamond(name, radius, center, length=None):
    """An octahedron (8 triangles): a glow that reads from any angle. `length` stretches it along Y."""
    ly = radius if length is None else length / 2.0
    verts = [(radius, 0, 0), (-radius, 0, 0), (0, ly, 0), (0, -ly, 0), (0, 0, radius), (0, 0, -radius)]
    faces = [
        [0, 2, 4], [2, 1, 4], [1, 3, 4], [3, 0, 4],
        [2, 0, 5], [1, 2, 5], [3, 1, 5], [0, 3, 5],
    ]
    return _object(name, verts, faces, center)


def spike(name, radius, length, base_center, square=False):
    """A four-sided pyramid pointing -Y with no base (4 triangles): a nozzle, a missile nose. Its base is a
    diamond (corners up, down and to the sides), or with `square` a square with flat sides."""
    if square:
        c = radius * math.sqrt(0.5)
        verts = [(c, 0, -c), (c, 0, c), (-c, 0, c), (-c, 0, -c), (0, -length, 0)]
    else:
        verts = [(radius, 0, 0), (0, 0, radius), (-radius, 0, 0), (0, 0, -radius), (0, -length, 0)]
    faces = [[0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4]]
    return _object(name, verts, faces, base_center)


def beam(name, size_x, size_z, length, start, pitch_deg=0.0, skip=("back",), top_scale=1.0):
    """A square-section bar from `start` running `length` forward (-Y), tipped up by pitch_deg: a barrel or boom.
    top_scale < 1 tapers its front end. Leaves out its back end by default (buried in a mantlet). Returns
    (obj, end_point)."""
    # built as a block standing on its back face, then turned so +Z points forward-and-up
    obj = block(
        name, size_x, size_z, length, top_x=size_x * top_scale, top_y=size_z * top_scale,
        skip=tuple({"back": "bottom", "front": "top", "bottom": "front", "top": "back"}.get(s, s) for s in skip),
    )
    tilt = math.pi / 2.0 - math.radians(pitch_deg)
    obj.rotation_euler = (tilt, 0.0, 0.0)
    obj.location = start
    end = (start[0], start[1] - math.sin(tilt) * length, start[2] + math.cos(tilt) * length)
    return obj, end


def finish(objects):
    """UV unwrap everything (no bevel: it would multiply the triangles)."""
    for obj in objects:
        common.smart_uv(obj)
    return objects
