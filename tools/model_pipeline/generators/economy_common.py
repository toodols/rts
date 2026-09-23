"""Helpers shared by the economy buildings (solar collectors, metal extractors, wind turbine, tidal generator)
and the scavenger beacons.

These models have a hard budget of 100 triangles each, so instead of common's closed, bevelled primitives they
are built from lean hand-made meshes: `Mesh` collects faces (lofts between two rings, pyramids, flat quads) into
one object, and leaves out whatever can never be seen -- the underside of anything standing on the ground or
floating, the top of a mast that a nacelle sits on, the inner end of a hinged panel. No bevels, no UVs (the
materials need none)."""

import math

import bmesh
import mathutils

from . import common

GOLD = (0.910, 0.784, 0.361, 1.0)  # Color3.fromRGB(232, 200, 92): the solar collectors
STEEL = (0.588, 0.627, 0.690, 1.0)  # Color3.fromRGB(150, 160, 176): the metal extractors
WIND = (0.478, 0.525, 0.580, 1.0)  # Color3.fromRGB(122, 134, 148): the wind turbine
TIDE = (0.376, 0.667, 0.839, 1.0)  # Color3.fromRGB(96, 170, 214): the tidal generator
SCAV = (0.588, 0.275, 0.784, 1.0)  # Color3.fromRGB(150, 70, 200): the scavenger beacons

SOLAR_CELL = (0.07, 0.11, 0.24, 1.0)  # deep blue photovoltaic glass
SOLAR_GLOW = (1.0, 0.82, 0.30, 1.0)
ORE_GLOW = (1.0, 0.55, 0.18, 1.0)  # molten ore glow in an extractor's throat
TIDE_GLOW = (0.35, 0.90, 1.0, 1.0)
SCAV_GLOW = (0.85, 0.25, 1.0, 1.0)
SCAV_DARK = (0.10, 0.08, 0.12, 1.0)  # the beacons' near-black, a touch purple


def accent(obj, key, color, roughness=0.4, metallic=0.35):
    """The team-tinted accent: `key` keeps each family's material distinct ("eco_accent_<key>")."""
    common.apply_material(obj, f"eco_accent_{key}", color, roughness=roughness, metallic=metallic)
    return obj


def glow(obj, key, color, emission=1.0):
    common.apply_material(obj, f"eco_glow_{key}", color, roughness=0.15, emission=emission)
    return obj


def cell(obj):
    common.apply_material(obj, "eco_solar_cell", SOLAR_CELL, roughness=0.18, metallic=0.55)
    return obj


def scav_dark(obj):
    common.apply_material(obj, "eco_scav_dark", SCAV_DARK, roughness=0.35, metallic=0.6)
    return obj


def body(obj):
    common.body_mat(obj)
    return obj


def trim(obj):
    common.trim_mat(obj)
    return obj


def ngon(radius, sides, rotation=0.0, xy=(0.0, 0.0), sy=None):
    """`sides` points round a circle (or an ellipse, with sy the Y radius), counter-clockwise from above."""
    ry = radius if sy is None else sy
    return [
        (xy[0] + radius * math.cos(rotation + 2.0 * math.pi * i / sides), xy[1] + ry * math.sin(rotation + 2.0 * math.pi * i / sides))
        for i in range(sides)
    ]


def rect(sx, sy, xy=(0.0, 0.0)):
    hx, hy = sx / 2.0, sy / 2.0
    x, y = xy
    return [(x - hx, y - hy), (x + hx, y - hy), (x + hx, y + hy), (x - hx, y + hy)]


def chamfered_rect(sx, sy, c):
    """An octagon made by cutting `c` off each corner of an sx by sy rectangle, centred on the origin."""
    hx, hy = sx / 2.0, sy / 2.0
    return [(-hx + c, -hy), (hx - c, -hy), (hx, -hy + c), (hx, hy - c), (hx - c, hy), (-hx + c, hy), (-hx, hy - c), (-hx, -hy + c)]


def at(points, z):
    return [(p[0], p[1], z) for p in points]


def matrix(location=(0.0, 0.0, 0.0), rotation=(0.0, 0.0, 0.0)):
    """A rigid transform: rotate by the XYZ euler `rotation` (radians), then move to `location`."""
    return mathutils.Matrix.Translation(location) @ mathutils.Euler(rotation, "XYZ").to_matrix().to_4x4()


class Mesh:
    """Faces collected into one object. Every shape is given in a local frame and moved by `m` (a matrix()),
    so a panel can be built flat and then hinged into place. Rings are counter-clockwise seen from their
    `top` side, which keeps every face's winding outward."""

    def __init__(self):
        self.verts = []
        self.faces = []

    def _add(self, points, m):
        base = len(self.verts)
        for p in points:
            v = m @ mathutils.Vector(p)
            self.verts.append((v.x, v.y, v.z))
        return list(range(base, base + len(points)))

    def loft(self, ring_a, ring_b, m=None, cap_a=False, cap_b=True, skip=()):
        """Sides between two rings of 3D points (a below/behind b), plus optional caps. `skip` names side
        indices (the side from point i to i+1) to leave out."""
        m = m or mathutils.Matrix.Identity(4)
        a = self._add(ring_a, m)
        b = self._add(ring_b, m)
        n = len(a)
        for i in range(n):
            if i in skip:
                continue
            j = (i + 1) % n
            self.faces.append((a[i], a[j], b[j], b[i]))
        if cap_b:
            self.faces.append(tuple(b))
        if cap_a:
            self.faces.append(tuple(reversed(a)))
        return self

    def frustum(self, bottom, top, z0, z1, m=None, cap_top=True, cap_bottom=False, skip=()):
        """A prism or frustum between two 2D rings (same point count) at heights z0 and z1."""
        return self.loft(at(bottom, z0), at(top, z1), m, cap_a=cap_bottom, cap_b=cap_top, skip=skip)

    def pyramid(self, ring, apex, m=None, cap=False):
        """Sides from a 3D ring up to an apex point."""
        m = m or mathutils.Matrix.Identity(4)
        r = self._add(ring, m)
        (p,) = self._add([apex], m)
        n = len(r)
        for i in range(n):
            self.faces.append((r[i], r[(i + 1) % n], p))
        if cap:
            self.faces.append(tuple(reversed(r)))
        return self

    def poly(self, points, m=None, double=False):
        """One flat face (3D points, counter-clockwise seen from its front); `double` adds the back too."""
        m = m or mathutils.Matrix.Identity(4)
        f = self._add(points, m)
        self.faces.append(tuple(f))
        if double:
            self.faces.append(tuple(reversed(self._add(points, m))))
        return self

    def build(self, name, location=(0.0, 0.0, 0.0)):
        """The object, with its origin at `location` (the geometry stays where it was built). A moving
        piece's pivot is its pivot object's location, so pass the pivot point here for that object."""
        obj = common.new_mesh_object(name)
        bm = bmesh.new()
        vs = [bm.verts.new((x - location[0], y - location[1], z - location[2])) for x, y, z in self.verts]
        for f in self.faces:
            bm.faces.new([vs[i] for i in f])
        bm.to_mesh(obj.data)
        bm.free()
        obj.location = location
        return obj


def tris(objects):
    return sum(len(p.vertices) - 2 for o in objects for p in o.data.polygons)


def wedge(mesh, angle, r_in, r_out, width, z0, height, m=None):
    """A buttress/claw: a right-triangle profile (flat on the ground, vertical at r_in, sloping down to r_out)
    extruded `width` across, pointing outward at `angle`. Its underside is left out."""
    base = matrix((0.0, 0.0, z0), (0.0, 0.0, angle - math.pi / 2))
    if m is not None:
        base = m @ base
    hw = width / 2.0
    # profile points (local y outward, z up), counter-clockwise seen from +x
    prof = [(r_in, 0.0), (r_out, 0.0), (r_in, height)]
    ring_a = [(-hw, y, z) for y, z in prof]
    ring_b = [(hw, y, z) for y, z in prof]
    # sides: 0 = underside, 1 = slope, 2 = inner face
    mesh.loft(ring_a, ring_b, base, cap_a=True, cap_b=True, skip=(0,))
    return mesh
