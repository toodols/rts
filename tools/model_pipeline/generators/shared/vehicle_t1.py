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

from . import common
from . import polygons


def prism(name, profile, width_bottom, width_top=None, origin=(0.0, 0.0, 0.0), caps="both", open_bottom=True):
    """A prism extruded along X from a side profile [(y, z), ...], centred on x = 0. Its half-width runs from
    width_bottom/2 at the profile's lowest z to width_top/2 at its highest, so the flanks can slope. `caps` is
    which ends are closed: "both", "left" (-X), "right" (+X) or "none"; `open_bottom` leaves out every edge face
    lying flat along the profile's lowest z (the floor)."""
    if width_top is None:
        width_top = width_bottom
    pts = list(profile)
    if polygons.signed_area(pts) < 0:
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
    return common.mesh(name, verts, faces, origin)


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
    return common.mesh(name, verts, faces, center)


def spike(name, radius, length, base_center, square=False):
    """A four-sided pyramid pointing -Y with no base (4 triangles): a nozzle, a missile nose. Its base is a
    diamond (corners up, down and to the sides), or with `square` a square with flat sides."""
    if square:
        c = radius * math.sqrt(0.5)
        verts = [(c, 0, -c), (c, 0, c), (-c, 0, c), (-c, 0, -c), (0, -length, 0)]
    else:
        verts = [(radius, 0, 0), (0, 0, radius), (-radius, 0, 0), (0, 0, -radius), (0, -length, 0)]
    faces = [[0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4]]
    return common.mesh(name, verts, faces, base_center)


def beam(name, size_x, size_z, length, start, pitch_deg=0.0, drop=("back",), top_scale=1.0):
    """A square-section bar from `start` running `length` forward (-Y), tipped up by pitch_deg: a barrel or boom.
    top_scale < 1 tapers its front end. Leaves out its back end by default (buried in a mantlet). Returns
    (obj, end_point)."""
    # built as a block standing on its back face, then turned so +Z points forward-and-up
    obj = common.block(name, size_x, size_z, length, top=(size_x * top_scale, size_z * top_scale), drop=tuple({"back": "bottom", "front": "top", "bottom": "front", "top": "back"}.get(s, s) for s in drop))
    tilt = math.pi / 2.0 - math.radians(pitch_deg)
    obj.rotation_euler = (tilt, 0.0, 0.0)
    obj.location = start
    end = (start[0], start[1] - math.sin(tilt) * length, start[2] + math.cos(tilt) * length)
    return obj, end
