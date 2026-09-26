"""Shared pieces for the Cortex anti-air towers and artillery: thistle, screamer, eradicator, agitator,
persecutor and scorpion (unit_defs/defense.luau).

These are low-poly on purpose: each whole model stays at or under 100 triangles. So they are built face by face,
with every face that can never be seen (a base on the ground, the end of a barrel buried in its mantlet) left out, and
no bevels, spheres or round cylinders.
A few strong shapes carry the silhouette; colour does the rest. A loft or block can give different faces
different materials at no cost in triangles (a launcher's front face dark, with lit tube mouths on it).

They belong to the same line as the Guard/Twin Guard/Warden (shared/tower.py): an octagonal plinth, a
column or base, and armored turret heads in the def's accent colour (the team colour in game). Missile pods
and barrels are laid out in a `Frame`, a coordinate system pitched up from the head's forward axis
(Blender -Y), as "x across, f forward along the barrel, u up across it".

A `Parts` collects one rigid piece's faces by material tag ("accent", "trim", "body", "glow") and becomes one
object per tag: build.py exports one colour per object, so a head that mixes colours is several objects
moving together, in one art group, pivoting on the accent object's origin (the swivel point).
"""

import math

import mathutils

from . import common
from . import palette

Vector = mathutils.Vector


class Frame:
    """A coordinate system at `origin`, pitched `elev` degrees up from forward (-Y). point(x, f, u): x across
    (+X), f forward, u up across the pitched axis. Frame() is the plain head frame: (x, -y, z)."""

    def __init__(self, origin=(0.0, 0.0, 0.0), elev=0.0):
        self.origin = Vector(origin)
        e = math.radians(elev)
        self.side = Vector((1.0, 0.0, 0.0))
        self.fwd = Vector((0.0, -math.cos(e), math.sin(e)))
        self.up = Vector((0.0, math.sin(e), math.cos(e)))

    def point(self, x, f, u):
        return self.origin + self.side * x + self.fwd * f + self.up * u


def ngon(n, r, z, rot=None, xy=(0.0, 0.0)):
    """common.ngon at height z, turned `rot` degrees, by default so a flat (not a corner) faces +X... and so -Y."""
    phase = math.radians(180.0 / n if rot is None else rot)
    return [Vector(p) for p in common.at(common.ngon(n, r, phase, xy), z)]


def square(width, z, xy=(0.0, 0.0)):
    """A square ring `width` across, sides facing the axes."""
    return ngon(4, width / math.sqrt(2.0), z, rot=45.0, xy=xy)


def _centroid(pts):
    c = Vector((0.0, 0.0, 0.0))
    for p in pts:
        c += p
    return c / len(pts)


class Parts:
    """Faces of one rigid piece, by material tag."""

    def __init__(self):
        self.tags = {}  # tag -> common.Faces

    def face(self, tag, pts, outward):
        """One polygon, wound so its normal points along `outward`. tag None drops it."""
        if tag is not None:
            self.tags.setdefault(tag, common.Faces()).polygon([Vector(p) for p in pts], outward)

    def loft(self, rings, side="body", top=None, bottom=None):
        """Quads between successive rings of equal size (a column, a plinth, a round-ish barrel), with
        optional end caps. `side` may be a list, one tag per section."""
        n = len(rings[0])
        cents = [_centroid(r) for r in rings]
        for k in range(len(rings) - 1):
            tag = side[k] if isinstance(side, (list, tuple)) else side
            a, b = rings[k], rings[k + 1]
            axis = cents[k + 1] - cents[k]
            for i in range(n):
                j = (i + 1) % n
                quad = [a[i], a[j], b[j], b[i]]
                c = _centroid(quad)
                t = (c - cents[k]).dot(axis) / max(axis.length_squared, 1e-9)
                self.face(tag, quad, c - (cents[k] + axis * t))
        self.face(top, rings[-1], cents[-1] - cents[-2])
        self.face(bottom, rings[0], cents[0] - cents[1])

    def hexa(self, corners, tags):
        """A convex eight-cornered block: corners are back ring (4) then front ring (4), each ring in the
        order (-x,-u), (+x,-u), (+x,+u), (-x,+u). tags maps back/front/left/right/bottom/top to a tag or None."""
        c = _centroid(corners)
        b, f = corners[:4], corners[4:]
        faces = {
            "back": b, "front": f,
            "bottom": [b[0], b[1], f[1], f[0]], "top": [b[3], b[2], f[2], f[3]],
            "left": [b[0], b[3], f[3], f[0]], "right": [b[1], b[2], f[2], f[1]],
        }
        for key, pts in faces.items():
            self.face(tags.get(key, tags.get("all")), pts, _centroid(pts) - c)

    def block_f(self, fr, x, u, f0, f1, back, front=None, front_shift_u=0.0, tags=None):
        """A block along the frame's forward axis from f0 to f1: `back` (width, height) at f0, `front` at f1
        (a chamfered launcher nose, a tapering mantlet)."""
        front = front or back
        ring = lambda f, s, du: [fr.point(x + sx * s[0] / 2, f, u + du + su * s[1] / 2)
                                 for sx, su in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        self.hexa(ring(f0, back, 0.0) + ring(f1, front, front_shift_u), tags or {"all": "accent"})

    def block_u(self, fr, x, f, u0, u1, bottom, top=None, top_shift_f=0.0, tags=None):
        """A block rising up the frame from u0 to u1: `bottom` (width, length) narrowing to `top`, whose centre
        moves forward by top_shift_f (negative pulls it back: a sloped glacis)."""
        top = top or bottom
        corners = []
        for u, s, df in ((u0, bottom, 0.0), (u1, top, top_shift_f)):
            for sx, sf in ((-1, -1), (1, -1), (1, 1), (-1, 1)):
                corners.append(fr.point(x + sx * s[0] / 2, f + df + sf * s[1] / 2, u))
        # reorder into hexa's back ring (the bottom) then front ring (the top): its "front" is then the top
        # face, and so on; translate the caller's tags into those terms
        t = tags or {"all": "accent"}
        mapped = {"back": t.get("bottom", t.get("all")), "front": t.get("top", t.get("all")),
                  "bottom": t.get("rear", t.get("all")), "top": t.get("fore", t.get("all")),
                  "left": t.get("left", t.get("all")), "right": t.get("right", t.get("all"))}
        self.hexa(corners, mapped)

    def tube_f(self, fr, n, r, f0, f1, x=0.0, u=0.0, r1=None, side="body", back=None, front=None):
        """An n-sided barrel along the frame's forward axis."""
        r1 = r if r1 is None else r1
        rot = math.radians(180.0 / n)
        rings = []
        for f, rr in ((f0, r), (f1, r1)):
            rings.append([fr.point(x + rr * math.cos(rot + 2 * math.pi * i / n), f,
                                   u + rr * math.sin(rot + 2 * math.pi * i / n)) for i in range(n)])
        self.loft(rings, side=side, top=front, bottom=back)

    def cone_f(self, fr, n, r, f0, length, x=0.0, u=0.0, tag="glow"):
        """An n-sided point along the frame's forward axis (a missile nose), sides only."""
        rot = math.radians(180.0 / n)
        ring = [fr.point(x + r * math.cos(rot + 2 * math.pi * i / n), f0, u + r * math.sin(rot + 2 * math.pi * i / n))
                for i in range(n)]
        tip = fr.point(x, f0 + length, u)
        for i in range(n):
            tri = [ring[i], ring[(i + 1) % n], tip]
            self.face(tag, tri, _centroid(tri) - fr.point(x, f0 + length * 0.3, u))

    def quad_f(self, fr, x, f, u, sx, su, tag="glow"):
        """A flat panel across the frame at f, facing forward (lit tube mouths on a launcher's face)."""
        pts = [fr.point(x + a * sx / 2, f, u + b * su / 2) for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        self.face(tag, pts, fr.fwd)

    def quad_u(self, fr, x, f, u, sx, sf, tag="trim"):
        """A flat panel lying on the frame at u, facing up (hatches on a deck)."""
        pts = [fr.point(x + a * sx / 2, f + b * sf / 2, u) for a, b in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        self.face(tag, pts, fr.up)

    def objects(self, name, origin, paints, order):
        """One object per tag, in `order`, each painted by `paints` (a common.Materials, whose kinds the tags are), its
        vertices (built as offsets from `origin`) moved there."""
        out = []
        o = Vector(origin)
        for tag in order:
            if tag not in self.tags:
                continue
            out += paints.paint(tag, self.tags[tag].build(f"{name}_{tag}", o))
        return out


# The order a piece's objects come in: accent first, so a head's accent object is its pivot.
ORDER = ("accent", "trim", "body", "glow")


def base_objects(parts, first_tag, accent_color):
    """The static base: the object of `first_tag` (the footing, which must be symmetric about the origin, as
    build.py centres the model on it) first."""
    order = sorted(ORDER, key=lambda tag: tag != first_tag)
    return parts.objects("base", (0.0, 0.0, 0.0), common.Materials(accent_color, palette.AA_BLUE), order)


def head_objects(parts, swivel, accent_color, glow_color=palette.AA_BLUE, weapon=1):
    """A turret head's objects at `swivel`, in group turret_<weapon> following that weapon's aim."""
    objs = parts.objects("turret", swivel, common.Materials(accent_color, glow_color), ORDER)
    group = f"turret_{weapon}"
    for i, obj in enumerate(objs):
        if i == 0:
            common.art_group(obj, group, pivot=True, kind="turret", weapon=weapon)
        else:
            common.art_group(obj, group)
    return objs
