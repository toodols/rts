"""Shared pieces for the T2 bots of unit_defs/bot_t2.luau (the Advanced Bot Lab's units).

The bots are held to 100 triangles a model, so they are built from a few hand-made low-poly solids: every piece is a `sweep` -- a run of four-cornered rings joined by quads, capped
at either end or not -- with faces nobody can see (a foot's sole, a leg's top buried in the hip, a barrel's back
end inside its housing) left out. A bent leg is one sweep through hip, knee and ankle; a torso is one sweep
through waist, chest and shoulders. There is no bevel: edges stay hard.

Every bot is built in world coordinates (studs, Blender Z up, facing -Y) through a `Bot`, which records each
piece's material and art group. build.py makes one MeshPart per (group, material), so a bot keeps to eight parts:
each walking leg is its own one-material piece (kind "leg", swinging about its hip; Bot.biped and Bot.leg), and the
rest is a few materials in the static `base` and the moving torso/turret or builder's head.
"""

import math

import bpy
import mathutils

from . import common
from . import palette


# --- rings: four corners each, in matching order along a sweep (sweep winds the faces outward itself) ---

def hring(x, y, z, w, d):
    """A horizontal rectangle w (X) by d (Y) centred on (x, y) at height z."""
    return common.at(common.rect(w, d, (x, y)), z)


def vring(x, y, z, w, h):
    """A rectangle standing across the Y axis: w (X) by h (Z) centred on (x, z), at depth y."""
    return [(x - w / 2, y, z - h / 2), (x + w / 2, y, z - h / 2), (x + w / 2, y, z + h / 2), (x - w / 2, y, z + h / 2)]


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


def build_mesh(name, faces):
    """faces: lists of 3-4 points each, already wound outward, as one object, with shared corners welded
    (common.Faces with `weld`)."""
    welded = common.Faces(weld=True)
    for face in faces:
        welded.polygon(face)
    return welded.build(name)


def _outward(face, inside):
    if common.newell(face).dot(_centre(face) - inside) < 0:
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
        n = common.newell(face)
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
    if common.newell(face).dot(mathutils.Vector(facing)) < 0:
        face.reverse()
    return [face]


class Bot:
    """Collects a bot's faces by (art group, material) -- each of which build.py makes one MeshPart -- and turns
    them into one object apiece (finish)."""

    def __init__(self, key, accent, glow=palette.SCOUT_EYE):
        self.key = key
        self.paints = common.Materials(accent, glow)
        self.faces = {}  # (group, mat) -> [faces], in the order first put
        self.groups = {}  # group -> (pivot point, meta)

    def put(self, mat, faces, group="base"):
        assert mat in common.Materials.KINDS, mat
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

    def finish(self):
        """The bot's objects, its footprint first: whichever still (non-leg) piece is most nearly centred on the
        origin, the bot being designed about it. A bot is built in world space before its collider is known, so its
        origin is moved onto the middle of that footprint here, before build.py fills the collider with it."""
        def is_leg(key):
            return self.groups.get(key[0], (None, {}))[1].get("kind") == "leg"

        objects = []
        # walking legs last: none of them is the footprint
        for group, mat in [k for k in self.faces if not is_leg(k)] + [k for k in self.faces if is_leg(k)]:
            obj = build_mesh(f"{self.key}_{group}_{mat}", self.faces[(group, mat)])
            self.paints.paint(mat, obj)
            if group != "base":
                pivot, meta = self.groups[group]
                common.set_pivot(obj, pivot)
                common.art_group(obj, group, pivot=True, **meta)
            objects.append(obj)
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
        common.centre_footprint(objects)
        bpy.context.view_layer.update()
        return objects
