"""Shared pieces for the T2 bots of unit_defs/bot_t2.luau (the Advanced Bot Lab's units).

The bots are held to 100 triangles a model, so they are built from a few hand-made low-poly solids rather than
common.py's bevelled primitives: every piece is a `sweep` -- a run of four-cornered rings joined by quads, capped
at either end or not -- with faces nobody can see (a foot's sole, a leg's top buried in the hip, a barrel's back
end inside its housing) left out. A bent leg is one sweep through hip, knee and ankle; a torso is one sweep
through waist, chest and shoulders. There is no bevel: edges stay hard.

Every bot is built in world coordinates (studs, Blender Z up, facing -Y) through a `Bot`, which records each
piece's material and art group. build.py makes one MeshPart per (group, material), so a bot keeps to eight parts:
each walking leg is its own one-material piece (kind "leg", swinging about its hip; Bot.biped and Bot.leg), and the
rest is a few materials in the static `base` and the moving torso/turret or builder's head.
"""

import math

import bmesh
import bpy
import mathutils

from . import common


def rgb(r, g, b):
    return (r / 255.0, g / 255.0, b / 255.0, 1.0)


def collider(w, h, l):
    """unit_defs' capsule(w, h, l) in studs: (radius, height)."""
    return max(w, l) / 22.0, h / 11.0


# --- rings: four corners each, in matching order along a sweep (sweep winds the faces outward itself) ---

def hring(x, y, z, w, d):
    """A horizontal rectangle w (X) by d (Y) centred on (x, y) at height z."""
    return [(x - w / 2, y - d / 2, z), (x + w / 2, y - d / 2, z), (x + w / 2, y + d / 2, z), (x - w / 2, y + d / 2, z)]


def vring(x, y, z, w, h):
    """A rectangle standing across the Y axis: w (X) by h (Z) centred on (x, z), at depth y."""
    return [(x - w / 2, y, z - h / 2), (x + w / 2, y, z - h / 2), (x + w / 2, y, z + h / 2), (x - w / 2, y, z + h / 2)]


def xring(x, y, z, d, h):
    """A rectangle standing across the X axis: d (Y) by h (Z) centred on (y, z), at x."""
    return [(x, y - d / 2, z - h / 2), (x, y + d / 2, z - h / 2), (x, y + d / 2, z + h / 2), (x, y - d / 2, z + h / 2)]


def oring(x, y, z, rx, ry=None, n=8, turn=0.5):
    """A horizontal n-gon of radii rx (X) and ry (Y) centred on (x, y) at height z; `turn` (in steps) rotates it,
    0.5 putting flats rather than corners toward the axes. Sweeps take these like any other ring."""
    ry = rx if ry is None else ry
    pts = []
    for i in range(n):
        a = 2.0 * math.pi * (i + turn) / n
        pts.append((x + rx * math.cos(a), y + ry * math.sin(a), z))
    return pts


def tri_ring(centre, heading, w, h):
    """A triangle standing across a horizontal `heading` (radians from +X): a flat base w wide, h below its
    apex. Legs swept through these have a ridge along the top, spider-style, for 3/4 of a box's triangles."""
    x, y, z = centre
    lx, ly = -math.sin(heading) * w / 2, math.cos(heading) * w / 2
    return [(x + lx, y + ly, z - h / 3), (x - lx, y - ly, z - h / 3), (x, y, z + 2 * h / 3)]


def _centre(points):
    n = len(points)
    return mathutils.Vector([sum(p[i] for p in points) / n for i in range(3)])


def _normal(points):
    """Newell's normal of a polygon (any number of corners), unnormalised."""
    n = mathutils.Vector((0.0, 0.0, 0.0))
    for i, p in enumerate(points):
        q = points[(i + 1) % len(points)]
        n.x += (p[1] - q[1]) * (p[2] + q[2])
        n.y += (p[2] - q[2]) * (p[0] + q[0])
        n.z += (p[0] - q[0]) * (p[1] + q[1])
    return n


def build_mesh(name, faces):
    """faces: lists of 3-4 points each, already wound outward. Shared corners are welded."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    verts = {}

    def vert(p):
        key = tuple(round(c, 5) for c in p)
        if key not in verts:
            verts[key] = bm.verts.new(key)
        return verts[key]

    for face in faces:
        unique = []
        for v in (vert(p) for p in face):
            if v not in unique:
                unique.append(v)
        if len(unique) < 3:
            continue
        try:
            bm.faces.new(unique)
        except ValueError:
            pass
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def _outward(face, inside):
    if _normal(face).dot(_centre(face) - inside) < 0:
        return list(reversed(face))
    return face


def sweep_faces(rings, cap_start=True, cap_end=True, skip=()):
    """The faces of a solid through `rings` (each four corners, in matching order): quads between neighbours,
    caps at the ends. `skip` lists directions ((x, y, z) vectors); faces facing one of them are left out (buried
    or never seen). Several sweeps' faces can be joined into one object with build_mesh."""
    faces = []
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        inside = _centre(a + b)
        n = len(a)
        for j in range(n):
            k = (j + 1) % n
            faces.append(_outward([a[j], a[k], b[k], b[j]], inside))
    if cap_start:
        faces.append(_outward(list(rings[0]), _centre(rings[0] + rings[1])))
    if cap_end:
        faces.append(_outward(list(rings[-1]), _centre(rings[-1] + rings[-2])))
    kept = []
    for face in faces:
        n = _normal(face)
        if n.length < 1e-9:
            continue
        n.normalize()
        if any(n.dot(mathutils.Vector(s).normalized()) > 0.75 for s in skip):
            continue
        kept.append(face)
    return kept


def sweep(name, rings, cap_start=True, cap_end=True, skip=()):
    """sweep_faces() as an object."""
    return build_mesh(name, sweep_faces(rings, cap_start, cap_end, skip))


def mirror_faces(faces):
    """The mirror image of faces across X = 0, rewound so they still face outward."""
    return [list(reversed([(-p[0], p[1], p[2]) for p in f])) for f in faces]


def mirrored(faces):
    """faces and their mirror image across X = 0 (rewound so they still face outward): a pair of legs as one
    symmetric piece."""
    return list(faces) + mirror_faces(faces)


DOWN = (0, 0, -1)
UP = (0, 0, 1)
FRONT = (0, -1, 0)
BACK = (0, 1, 0)
LEFT = (-1, 0, 0)
RIGHT = (1, 0, 0)


def block_faces(w, d, h, origin=(0.0, 0.0, 0.0), top=None, top_offset=(0.0, 0.0), skip=(DOWN,)):
    """A box (or, with top=(tw, td), a frustum) w by d by h standing from origin; its bottom is left out unless
    `skip` says otherwise."""
    x, y, z = origin
    tw, td = top if top is not None else (w, d)
    return sweep_faces([hring(x, y, z, w, d), hring(x + top_offset[0], y + top_offset[1], z + h, tw, td)], skip=skip)


def block(name, w, d, h, origin=(0.0, 0.0, 0.0), top=None, top_offset=(0.0, 0.0), skip=(DOWN,)):
    return build_mesh(name, block_faces(w, d, h, origin, top, top_offset, skip))


def pyramid_faces(ring, apex, cap=False):
    """Four triangles from a ring to an apex (a muzzle glow, a spike, a nose); `cap` closes the ring."""
    inside = _centre(list(ring) + [apex])
    faces = [_outward([ring[j], ring[(j + 1) % len(ring)], apex], inside) for j in range(len(ring))]
    if cap:
        faces.append(_outward(list(ring), inside))
    return faces


def panel_faces(ring, facing):
    """One polygon (a quad is two triangles) turned to face `facing`: visors, vents, lenses, lids."""
    face = list(ring)
    if _normal(face).dot(mathutils.Vector(facing)) < 0:
        face.reverse()
    return [face]


def set_pivot(obj, point):
    """Moves an object's origin to `point` without moving its geometry, so it can be its art group's pivot."""
    offset = mathutils.Vector(point) - obj.location
    obj.data.transform(mathutils.Matrix.Translation(-offset))
    obj.location = mathutils.Vector(point)
    return obj


MATERIALS = ("body", "trim", "accent", "glow", "hivis")


class Bot:
    """Collects a bot's faces by (art group, material) -- each of which build.py makes one MeshPart -- and turns
    them into one object apiece. The first material put in the base is the footprint build.py centres the model
    on; finish() centres it itself, so the fit report is the model as the game places it."""

    def __init__(self, key, accent, glow=(1.0, 0.35, 0.2, 1.0), collider=None):
        self.key = key
        self.accent = accent
        self.glow = glow
        self.collider = collider  # (radius, height) in studs, checked by finish()
        self.faces = {}  # (group, mat) -> [faces], in the order first put
        self.groups = {}  # group -> (pivot point, meta)

    def put(self, mat, faces, group="base"):
        assert mat in MATERIALS, mat
        self.faces.setdefault((group, mat), []).extend(faces)

    def group(self, name, pivot, **meta):
        """Declares a moving group: it turns about `pivot`; `meta` says how (common.art_group: kind, weapon,
        axis, speed)."""
        self.groups[name] = (pivot, meta)

    def leg(self, name, mat, faces, pivot, axis, swing, stride, phase):
        """A walking leg: its own rigid piece (one material) that swings `swing` radians either way about `axis`
        through `pivot` (its hip), once per `stride` studs walked, `phase` of a cycle apart from the others."""
        self.group(name, pivot, kind="leg", axis=axis, swing=swing, phase=phase, stride=stride)
        self.put(mat, faces, name)

    def biped(self, mat, faces, hip, swing):
        """A pair of walking legs from `faces`, built on the +X side with its hip joint at `hip`, mirrored for -X.
        They swing about X, half a cycle apart, and stride 4 * hip height * sin(swing), about what the feet cover
        in a cycle, so they don't visibly slide. The unit faces -Y, so its left is +X: leg_l."""
        stride = round(4.0 * hip[2] * math.sin(swing), 3)
        self.leg("leg_l", mat, faces, hip, (1, 0, 0), swing, stride, 0.0)
        self.leg("leg_r", mat, mirror_faces(faces), (-hip[0], hip[1], hip[2]), (1, 0, 0), swing, stride, 0.5)

    def _material(self, obj, mat):
        if mat == "body":
            common.body_mat(obj)
        elif mat == "trim":
            common.trim_mat(obj)
        elif mat == "accent":
            common.apply_material(obj, f"bot_t2_accent_{self.key}", self.accent, roughness=0.4, metallic=0.15)
        elif mat == "glow":
            common.apply_material(obj, f"bot_t2_glow_{self.key}", self.glow, roughness=0.2, emission=1.0)
        elif mat == "hivis":
            # the builders' nanolathe yellow, which stays yellow whatever the team (it has no "accent" in its name)
            common.apply_material(obj, "bot_t2_hivis", (1.0, 0.78, 0.08, 1.0), roughness=0.35, metallic=0.05)

    def finish(self):
        objects = []
        # the footprint build.py centres on is the first object, so it must not be one leg: legs go last
        def is_leg(key):
            return self.groups.get(key[0], (None, {}))[1].get("kind") == "leg"

        keys = [k for k in self.faces if not is_leg(k)] + [k for k in self.faces if is_leg(k)]
        for group, mat in keys:
            faces = self.faces[(group, mat)]
            obj = build_mesh(f"{self.key}_{group}_{mat}", faces)
            self._material(obj, mat)
            if group != "base":
                pivot, meta = self.groups[group]
                set_pivot(obj, pivot)
                common.art_group(obj, group, pivot=True, **meta)
            objects.append(obj)
        # build.py centres the model on the first object's bounds. The model is designed centred on the origin, so
        # put first whichever still (non-leg) piece is most nearly centred there, and centre on it as build.py will
        bpy.context.view_layer.update()

        def off_centre(obj):
            if obj.get("art_kind") == "leg":
                return float("inf")
            ws = [obj.matrix_world @ v.co for v in obj.data.vertices]
            return math.hypot((min(w.x for w in ws) + max(w.x for w in ws)) / 2,
                              (min(w.y for w in ws) + max(w.y for w in ws)) / 2)

        first = min(objects, key=off_centre)
        objects.remove(first)
        objects.insert(0, first)
        xs = [(first.matrix_world @ v.co).x for v in first.data.vertices]
        ys = [(first.matrix_world @ v.co).y for v in first.data.vertices]
        cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
        for obj in objects:
            obj.location.x -= cx
            obj.location.y -= cy
        print(f"bot_t2 footprint {first.name}: centred by ({-cx:.3f}, {-cy:.3f})")
        bpy.context.view_layer.update()
        self.report(objects)
        return objects

    def _swung(self, obj, sign):
        """obj's world vertices with a leg piece turned `sign` * its swing about its pivot."""
        pts = [obj.matrix_world @ v.co for v in obj.data.vertices]
        if obj.get("art_kind") != "leg":
            return pts
        rot = mathutils.Matrix.Rotation(sign * obj["art_swing"], 4, mathutils.Vector(tuple(obj["art_axis"])))
        pivot = obj.location.copy()
        return [pivot + rot @ (p - pivot) for p in pts]

    def report(self, objects):
        tris = 0
        reach = 0.0
        top = 0.0
        low = 0.0
        for obj in objects:
            tris += sum(len(p.vertices) - 2 for p in obj.data.polygons)
            # legs are checked at both ends of their swing too
            for w in self._swung(obj, 0.0) + self._swung(obj, 1.0) + self._swung(obj, -1.0):
                reach = max(reach, math.hypot(w.x, w.y))
                top = max(top, w.z)
                low = min(low, w.z)
        line = f"bot_t2 fit {self.key}: {tris} tris, {len(objects)} parts, reach {reach:.3f}, top {top:.3f}, low {low:.3f}"
        if self.collider:
            r, h = self.collider
            line += f" (collider r {r:.3f} h {h:.3f})"
            if reach > r + 1e-3 or top > h + 1e-3:
                line += " OUTSIDE"
        for obj in objects:
            if obj.get("art_kind") == "leg" and obj.get("art_pivot"):
                p = obj.location
                line += (f"\n  {obj['art_group']}: pivot ({p.x:.3f}, {p.y:.3f}, {p.z:.3f}) axis {tuple(obj['art_axis'])} "
                         f"swing {obj['art_swing']} stride {obj['art_stride']} phase {obj['art_phase']}")
        if tris > 100 or len(objects) > 8:
            line += " OVER-BUDGET"
        print(line)
