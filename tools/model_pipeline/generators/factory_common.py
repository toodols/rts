"""Shared helpers for the factories in unit_defs/factory.luau: bot_lab, advanced_bot_lab, vehicle_lab,
advanced_vehicle_lab, experimental_gantry, shipyard and air_lab.

production.luau puts a factory's next unit just outside its footprint along its facing, Roblox +Z, which is
Blender -Y here: every factory is open on its -Y side, its bay floor running out to that edge, and its yellow
nanolathe arms reach out over the front lip toward the spot where the unit is built.

Every factory is held to 100 triangles, so nothing here is bevelled and shapes are built face by face with the
faces nobody can see (undersides, faces pressed against a neighbour) left out: `Shape` collects hulls (boxes
whose top can be a different rectangle, for glacis and sloped walls), square beams bent along a path (nanolathe
arms), pyramids (emitter glows), flat decals and n-gon prisms into one mesh object per material.

Palette: the shared gunmetal body and near-black trim, the def's color as the team accent, high-vis yellow
nanolathe arms (the construction turret's yellow) with green-cyan glowing emitters.
"""

import math

import bmesh
import mathutils

from . import common

# unit_defs/factory.luau: every lab is Color3.fromRGB(122, 134, 148)
ACCENT_COLOR = (122 / 255.0, 134 / 255.0, 148 / 255.0, 1.0)
NANO_COLOR = (0.886, 0.698, 0.290, 1.0)  # the construction turret's high-vis yellow
GLOW_COLOR = (0.35, 0.95, 0.75, 1.0)  # nanolathe green-cyan

V = mathutils.Vector


class Kit:
    """Material setters for one factory, so each def's team accent material has a name of its own."""

    def __init__(self, tag, accent_color=ACCENT_COLOR):
        self.tag = tag
        self.accent_color = tuple(accent_color)

    def body(self, obj):
        common.body_mat(obj)
        return obj

    def trim(self, obj):
        common.trim_mat(obj)
        return obj

    def accent(self, obj):
        common.apply_material(obj, f"fac_accent_{self.tag}", self.accent_color, roughness=0.4, metallic=0.25)
        return obj

    def nano(self, obj):
        common.apply_material(obj, "fac_nano_yellow", NANO_COLOR, roughness=0.38, metallic=0.1)
        return obj

    def glow(self, obj):
        common.apply_material(obj, "fac_nano_glow", GLOW_COLOR, roughness=0.15, emission=1.0)
        return obj


class Shape:
    """Faces gathered into one mesh. Each piece's faces are turned to face away from that piece's own centre
    (or along a given normal, for decals), so pieces can leave faces out and still face outward."""

    def __init__(self):
        self.verts = []
        self.faces = []

    def _add(self, points):
        base = len(self.verts)
        self.verts.extend(V(p) for p in points)
        return base

    def _face(self, idx, centre=None, normal=None):
        pts = [self.verts[i] for i in idx]
        n = V((0.0, 0.0, 0.0))
        for i in range(len(pts)):
            n += pts[i].cross(pts[(i + 1) % len(pts)])
        mid = sum(pts, V((0.0, 0.0, 0.0))) / len(pts)
        out = V(normal) if normal is not None else mid - V(centre)
        if n.dot(out) < 0.0:
            idx = list(reversed(idx))
        self.faces.append(list(idx))

    def hull(self, bottom, top, z0, z1, drop=("bottom",)):
        """A box from rectangle `bottom` (x0, x1, y0, y1) at z0 to rectangle `top` at z1. `drop` names faces to
        leave out: bottom, top, front (-Y), back (+Y), left (-X), right (+X)."""
        bx0, bx1, by0, by1 = bottom
        tx0, tx1, ty0, ty1 = top
        b = self._add([(bx0, by0, z0), (bx1, by0, z0), (bx1, by1, z0), (bx0, by1, z0)])
        t = self._add([(tx0, ty0, z1), (tx1, ty0, z1), (tx1, ty1, z1), (tx0, ty1, z1)])
        c = V(((bx0 + bx1 + tx0 + tx1) / 4.0, (by0 + by1 + ty0 + ty1) / 4.0, (z0 + z1) / 2.0))
        faces = {
            "bottom": [b, b + 1, b + 2, b + 3],
            "top": [t, t + 1, t + 2, t + 3],
            "front": [b, b + 1, t + 1, t],
            "right": [b + 1, b + 2, t + 2, t + 1],
            "back": [b + 2, b + 3, t + 3, t + 2],
            "left": [b + 3, b, t, t + 3],
        }
        for name, idx in faces.items():
            if name not in drop:
                self._face(idx, centre=c)
        return self

    def box(self, x0, x1, y0, y1, z0, z1, drop=("bottom",)):
        return self.hull((x0, x1, y0, y1), (x0, x1, y0, y1), z0, z1, drop)

    def prism(self, centre, r, z0, z1, sides=6, r2=None, drop=("bottom",), turn=0.0):
        """An n-sided prism (or frustum with r2) standing on z0; its top is one n-gon."""
        r2 = r if r2 is None else r2
        cx, cy = centre

        def ring(rad, z):
            return [(cx + rad * math.cos(turn + 2 * math.pi * i / sides), cy + rad * math.sin(turn + 2 * math.pi * i / sides), z)
                    for i in range(sides)]

        b = self._add(ring(r, z0))
        t = self._add(ring(r2, z1))
        c = V((cx, cy, (z0 + z1) / 2.0))
        for i in range(sides):
            j = (i + 1) % sides
            self._face([b + i, b + j, t + j, t + i], centre=c)
        if "top" not in drop:
            self._face([t + i for i in range(sides)], centre=c)
        if "bottom" not in drop:
            self._face([b + i for i in range(sides)], centre=c)
        return self

    def quad(self, p0, p1, p2, p3, normal):
        """A flat decal facing `normal` (float it a hair off the surface it lies on)."""
        i = self._add([p0, p1, p2, p3])
        self._face([i, i + 1, i + 2, i + 3], normal=normal)
        return self

    def path(self, points, w, h=None):
        """A square-section beam (w wide, h deep) bent through `points`, its ends left open. Returns the last
        ring's corners, for cap()."""
        h = w if h is None else h
        pts = [V(p) for p in points]
        rings = []
        for i, p in enumerate(pts):
            if i == 0:
                d = pts[1] - pts[0]
            elif i == len(pts) - 1:
                d = pts[-1] - pts[-2]
            else:
                d = (pts[i + 1] - pts[i]).normalized() + (pts[i] - pts[i - 1]).normalized()
            d.normalize()
            side = V((0.0, 0.0, 1.0)).cross(d)
            if side.length < 1e-4:
                side = V((1.0, 0.0, 0.0))
            side.normalize()
            up = d.cross(side)
            rings.append(self._add([p + side * (sx * w / 2.0) + up * (sy * h / 2.0) for sx, sy in ((1, 1), (-1, 1), (-1, -1), (1, -1))]))
        for i in range(len(pts) - 1):
            c = (pts[i] + pts[i + 1]) / 2.0
            for k in range(4):
                m = (k + 1) % 4
                self._face([rings[i] + k, rings[i] + m, rings[i + 1] + m, rings[i + 1] + k], centre=c)
        return [self.verts[rings[-1] + k] for k in range(4)]

    def cap(self, ring, apex):
        """A pyramid from the corners `ring` to `apex`, base left open (an emitter glow on an arm's end)."""
        base = self._add(ring)
        a = self._add([apex])
        c = sum(ring, V((0.0, 0.0, 0.0))) / len(ring)
        for k in range(len(ring)):
            self._face([base + k, base + (k + 1) % len(ring), a], centre=c)
        return self

    def build(self, name):
        obj = common.new_mesh_object(name)
        bm = bmesh.new()
        bverts = [bm.verts.new(p) for p in self.verts]
        for idx in self.faces:
            bm.faces.new([bverts[i] for i in idx])
        bm.to_mesh(obj.data)
        bm.free()
        return obj


def chevron(shape, cx, y_tip, z, width, bar, point=-1.0):
    """A floor chevron (two parallelogram decals) with its tip at y_tip, pointing `point` along Y."""
    half = width / 2.0
    back = -point * half * 0.8
    for sx in (-1.0, 1.0):
        shape.quad((cx, y_tip, z), (cx + sx * half, y_tip + back, z), (cx + sx * half, y_tip + back - point * bar, z),
                   (cx, y_tip - point * bar, z), normal=(0, 0, 1))


def nano_arm(shape, glow, points, target, w=0.5, reach=1.6, glow_len=0.6):
    """A yellow nanolathe arm: a square beam through `points` (root first, root buried in whatever it is mounted
    on), then `reach` studs straight at `target`, capped with a glowing pyramid pointing at it. 8 triangles a
    segment and 4 for the glow."""
    e = V(points[-1])
    d = (V(target) - e).normalized()
    wrist = e + d * reach
    ring = shape.path(list(points) + [tuple(wrist)], w)
    glow.cap(ring, tuple(wrist + d * glow_len))
    return wrist


def finish(objs):
    """No bevels (they multiply triangles): UVs only."""
    for obj in objs:
        common.smart_uv(obj)
    return objs
