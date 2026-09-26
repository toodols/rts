"""Shared low-poly builders for the first tier of ships (src/shared/unit_defs/ship_t1.luau).

Every ship is held to 100 triangles for the whole model, so everything here builds its mesh face by face and leaves
out whatever cannot be seen: the underside of anything that sits on a deck, the back of a barrel inside its gun
house, and the hull's bottom, which is under the water. Nothing is bevelled.

A ship's collider's bottom rides on the water's surface (unit_defs.surface_height), so z = 0 is the waterline and a
model sits between it and the collider's height, inside the collider's circle. The bow points Blender -Y (Roblox
+Z, the way a model faces). A hull is two outlines, the deck's and a narrower one at the waterline, joined by its
sides: the flare and the raked stem are what make it read as a ship. The deck is its own single face in the dark
trim, so from above the gunmetal superstructure and the team-coloured turrets stand out against it.
"""

import math

from . import common
from . import polygons


# ---------------------------------------------------------------------------------------------------------------
# Meshes, face by face


def mesh(name, verts, faces, origin=(0.0, 0.0, 0.0)):
    """common.mesh, but through Mesh.from_pydata: the edges come out in another order than bmesh builds them in,
    which is what the ships' uploaded meshes were hashed from, so the ships keep it."""
    obj = common.new_mesh_object(name)
    obj.data.from_pydata([tuple(v) for v in verts], [], [tuple(f) for f in faces])
    obj.data.update()
    obj.location = origin
    return obj


def loft(name, rings, cap_first=False, cap_last=True, origin=(0.0, 0.0, 0.0)):
    """A solid through `rings` (lists of 3D points), running along some direction d: each ring goes round
    counter-clockwise seen from ahead of it (from +d). A ring of one point closes to a tip. Only the caps asked for
    are made: the first, at the back, is usually hidden."""
    verts, faces, idx = [], [], []
    for ring in rings:
        idx.append(list(range(len(verts), len(verts) + len(ring))))
        verts.extend(ring)
    for a, b in zip(idx, idx[1:]):
        if len(a) == 1:
            n = len(b)
            faces += [(a[0], b[(i + 1) % n], b[i]) for i in range(n)]
        elif len(b) == 1:
            n = len(a)
            faces += [(a[i], a[(i + 1) % n], b[0]) for i in range(n)]
        else:
            n = len(a)
            faces += [(a[i], a[(i + 1) % n], b[(i + 1) % n], b[i]) for i in range(n)]
    if cap_first and len(idx[0]) > 2:
        faces.append(tuple(reversed(idx[0])))
    if cap_last and len(idx[-1]) > 2:
        faces.append(tuple(idx[-1]))
    return mesh(name, verts, faces, origin)


def block(name, w, l, h, tw=None, tl=None, off=(0.0, 0.0), origin=(0.0, 0.0, 0.0), bottom=False):
    """A box, or with tw/tl a frustum whose top is that size and shifted by `off`, standing up from `origin`,
    with no bottom face unless asked: 10 triangles."""
    tw = w if tw is None else tw
    tl = l if tl is None else tl
    ring = [(-1, -1), (1, -1), (1, 1), (-1, 1)]
    lo = [(sx * w / 2, sy * l / 2, 0.0) for sx, sy in ring]
    hi = [(off[0] + sx * tw / 2, off[1] + sy * tl / 2, h) for sx, sy in ring]
    return loft(name, [lo, hi], cap_first=bottom, cap_last=True, origin=origin)


def prism(name, outline, h, top_outline=None, top_z=None, origin=(0.0, 0.0, 0.0)):
    """An upright prism from any convex (x, y) outline, top optionally a different outline; no bottom face."""
    lo = outline if polygons.signed_area(outline) > 0 else list(reversed(outline))
    hi = top_outline or lo
    if polygons.signed_area(hi) < 0:
        hi = list(reversed(hi))
    return loft(name, [[(x, y, 0.0) for x, y in lo], [(x, y, h if top_z is None else top_z) for x, y in hi]],
                origin=origin)


def spire(name, w, l, h, origin=(0.0, 0.0, 0.0), sides=3):
    """A pyramid (a mast, an aerial) with no base: `sides` triangles."""
    ring = common.at(common.ngon(sides, w / 2, math.pi / 2, radius_y=l / 2), 0.0)
    return loft(name, [ring, [(0.0, 0.0, h)]], origin=origin)


def bar(name, w, h, length, y_start, z, x=0.0, sides=3, taper=1.0, cap=True):
    """A barrel or boom along -Y from y_start: a prism of `sides` (3 is a ridge-topped triangle, 4 a box), with no
    back face. 3 sides is 7 triangles, 4 is 10."""
    if sides == 3:
        sec = [(-w / 2, -h / 2), (w / 2, -h / 2), (0.0, h / 2)]
    else:
        sec = [(-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)]
    back = [(x + sx, y_start, z + sz) for sx, sz in sec]
    front = [(x + sx * taper, y_start - length, z + sz * taper) for sx, sz in sec]
    return loft(name, [back, front], cap_first=False, cap_last=cap)


def beam(name, p0, p1, w, h, cap=True, taper=1.0):
    """A 3-sided (ridge-up) beam from p0 to p1, with no face at p0: 7 triangles, or 6 without the end cap."""
    d = [p1[i] - p0[i] for i in range(3)]
    n = math.sqrt(sum(c * c for c in d))
    d = [c / n for c in d]
    side = [d[1], -d[0], 0.0]  # d x Z, horizontal
    sn = math.sqrt(sum(c * c for c in side)) or 1.0
    side = [c / sn for c in side]
    up = [side[1] * d[2] - side[2] * d[1], side[2] * d[0] - side[0] * d[2], side[0] * d[1] - side[1] * d[0]]
    if up[2] < 0:
        up = [-c for c in up]
    sec = [(-w / 2, -h / 2), (w / 2, -h / 2), (0.0, h / 2)]

    def ring(p, k):
        return [tuple(p[i] + k * (a * side[i] + b * up[i]) for i in range(3)) for a, b in sec]

    r0, r1 = ring(p0, 1.0), ring(p1, taper)
    # counter-clockwise seen from ahead (from +d)
    a, b, c = r0
    cross = [(b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]),
             (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]),
             (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])]
    if sum(cross[i] * d[i] for i in range(3)) < 0:
        r0, r1 = list(reversed(r0)), list(reversed(r1))
    return loft(name, [r0, r1], cap_first=False, cap_last=cap)


def point_cone(name, base_center, tip, r, sides=4):
    """A cone of `sides` from a ring round base_center to a point at tip, with its base face: sides + sides-2
    triangles (a nozzle, an emitter)."""
    d = [tip[i] - base_center[i] for i in range(3)]
    n = math.sqrt(sum(c * c for c in d))
    d = [c / n for c in d]
    ref = [0.0, 0.0, 1.0] if abs(d[2]) < 0.9 else [1.0, 0.0, 0.0]
    u = [d[1] * ref[2] - d[2] * ref[1], d[2] * ref[0] - d[0] * ref[2], d[0] * ref[1] - d[1] * ref[0]]
    un = math.sqrt(sum(c * c for c in u))
    u = [c / un for c in u]
    v = [d[1] * u[2] - d[2] * u[1], d[2] * u[0] - d[0] * u[2], d[0] * u[1] - d[1] * u[0]]
    ring = [tuple(base_center[i] + r * (math.cos(2 * math.pi * k / sides) * u[i] + math.sin(2 * math.pi * k / sides) * v[i])
                  for i in range(3)) for k in range(sides)]
    a, b, c = ring[0], ring[1], ring[2]
    cross = [(b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]),
             (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]),
             (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])]
    if sum(cross[i] * d[i] for i in range(3)) < 0:
        ring = list(reversed(ring))
    return loft(name, [ring, [tuple(tip)]], cap_first=True, cap_last=False)


def quad(name, corners):
    """One face (a window, a painted panel), its corners counter-clockwise seen from the side it shows."""
    return mesh(name, corners, [tuple(range(len(corners)))])


def deck_panel(name, points_xy, z, lift=0.006):
    """A flat panel lying at height z, facing up."""
    pts = points_xy if polygons.signed_area(points_xy) > 0 else list(reversed(points_xy))
    return quad(name, [(x, y, z + lift) for x, y in pts])


def fin(name, pts):
    """A flat polygon seen from both sides (a fin, a blade): each side its own face and vertices."""
    n = len(pts)
    return mesh(name, list(pts) + list(pts), [tuple(range(n)), tuple(reversed(range(n, 2 * n)))])


def chevron(name, hull, tip_y, half_span, depth, thick, lift=0.02):
    """A flat team-coloured V on the deck, its point forward at tip_y: 2 triangles."""
    pts = [(0.0, tip_y), (half_span, tip_y + depth), (0.0, tip_y + thick), (-half_span, tip_y + depth)]
    top = max(hull.deck_at(y) for _, y in pts) + lift
    return mesh(name, [(x, y, top) for x, y in pts], [(0, 1, 2), (0, 2, 3)])


def front_window(name, w, h, y, z, x=0.0, lean=0.0):
    """A glowing window strip facing forward (-Y), leaning back by `lean` at its top: 2 triangles."""
    return quad(name, [(x - w / 2, y, z), (x + w / 2, y, z), (x + w / 2, y + lean, z + h), (x - w / 2, y + lean, z + h)])


# ---------------------------------------------------------------------------------------------------------------
# Hulls


class Hull:
    """A hull from its deck outline, `plan`: (t, half-width fraction) from the transom (t = 0, +Y) forward, ending
    at the stem (t = 1, width 0). The waterline outline is the deck's narrowed by `flare`, with the stem raked back
    by `rake` of the length. The deck rises by `sheer` toward the bow; `x` and `y` move it off the centre (a multihull's
    side hulls). Its triangles: 4 per plan point for the sides and the deck, less a few."""

    def __init__(self, length, beam, depth, plan, sheer=0.2, flare=0.78, rake=0.08, stern_rake=0.0, x=0.0, y=0.0):
        self.length, self.beam, self.depth, self.x, self.y0 = length, beam, depth, x, y
        self.plan, self.sheer, self.flare, self.rake, self.stern_rake = plan, sheer, flare, rake, stern_rake

    def y(self, t):
        return self.y0 + self.length / 2.0 - t * self.length

    def deck_z(self, t):
        u = max(0.0, (t - 0.45) / 0.55)
        return self.depth + self.sheer * u * u

    def half_width(self, y):
        t = (self.y0 + self.length / 2.0 - y) / self.length
        for (t0, w0), (t1, w1) in zip(self.plan, self.plan[1:]):
            if t0 <= t <= t1:
                f = (t - t0) / max(t1 - t0, 1e-6)
                return self.beam / 2 * (w0 + (w1 - w0) * f)
        return 0.0

    def deck_at(self, y):
        t = min(max((self.y0 + self.length / 2.0 - y) / self.length, 0.0), 1.0)
        return self.deck_z(t)

    def _outline(self, top):
        right = []
        for t, w in self.plan:
            if top:
                right.append((self.beam / 2 * w, self.y(t), self.deck_z(t)))
            else:
                t2 = t
                if t >= 1.0:
                    t2 = t - self.rake
                elif t <= 0.0:
                    t2 = t + self.stern_rake
                right.append((self.beam / 2 * w * self.flare, self.y(t2), 0.0))
        tip, right = right[-1], right[:-1]
        ring = [(tip[0] * 0, tip[1], tip[2])] + list(reversed(right)) + [(-x, y, z) for x, y, z in right]
        if polygons.signed_area([(x, y) for x, y, _ in ring]) < 0:
            ring = list(reversed(ring))
        return [(x + self.x, y, z) for x, y, z in ring]

    def build(self, name="hull"):
        lo, hi = self._outline(False), self._outline(True)
        return loft(name, [lo, hi], cap_first=False, cap_last=False)

    def build_deck(self, name="deck"):
        hi = self._outline(True)
        return mesh(name, [(x, y, z + 0.003) for x, y, z in hi], [tuple(range(len(hi)))])
