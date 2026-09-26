"""Shared parts for the T1 bots (unit_defs/bot_t1.luau): construction_bot, grunt, tick, thug, aggravator,
trasher, graverobber, centurion.

Each bot has a hard budget of 100 triangles for the whole model, so everything here is built face by
face: a piece is a hexahedron (any 4 corners at
the bottom, any 4 at the top) with only the faces the camera can see. The RTS camera looks down from
well above, so bottoms are never built, and a cap that sits inside another piece is left off too.
Nothing is bevelled; the flat-shaded facets are the look, like Total Annihilation's own low-poly units.

Every model splits into the same moving pieces: legs are the static "base"; the torso and everything
on it (arms, weapons, head) is one piece that turns with the weapon's aim (or, for a builder, toward
what it builds). Materials are body + trim + one team accent + one glow, at most six parts a model.
"""

import math

import mathutils

from . import common


def hexa(name, bottom, top, caps="t"):
    """A six-sided block from 4 bottom and 4 top corners, both counter-clockwise seen from above (from
    the top end), corner i of the bottom joined to corner i of the top. `caps` says which ends are
    closed: "t" top, "b" bottom, "" neither (both hidden). Built in world space, origin at 0."""
    faces = [(i, (i + 1) % 4, 4 + (i + 1) % 4, 4 + i) for i in range(4)]
    if "t" in caps:
        faces.append((4, 5, 6, 7))
    if "b" in caps:
        faces.append((3, 2, 1, 0))
    return common.mesh(name, list(bottom) + list(top), faces)


def _rect(cx, cy, z, w, d):
    return common.at(common.rect(w, d, (cx, cy)), z)


def slab(name, w, d, h, top_w=None, top_d=None, top_offset=(0.0, 0.0), origin=(0.0, 0.0, 0.0), caps="t"):
    """An upright block (tapered when top_w/top_d differ) standing base-up from origin: 10 triangles."""
    x, y, z = origin
    tw = w if top_w is None else top_w
    td = d if top_d is None else top_d
    return hexa(name, _rect(x, y, z, w, d), _rect(x + top_offset[0], y + top_offset[1], z + h, tw, td), caps)


def beam(name, p0, p1, w, d, w1=None, d1=None, caps="t"):
    """A block running from p0 to p1, w by d across at p0 (w1 by d1 at p1), its width kept along X as
    far as the direction allows: limbs, barrels, launch rails. "t" caps the p1 end, "b" the p0 end."""
    a = mathutils.Vector(p1) - mathutils.Vector(p0)
    an = a.normalized()
    ref = mathutils.Vector((1.0, 0.0, 0.0))
    if abs(an.dot(ref)) > 0.95:
        ref = mathutils.Vector((0.0, 0.0, 1.0))
    u = (ref - an * ref.dot(an)).normalized()
    v = an.cross(u)

    def ring(p, ww, dd):
        p = mathutils.Vector(p)
        return [tuple(p + u * (sx * ww / 2.0) + v * (sy * dd / 2.0)) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]

    return hexa(name, ring(p0, w, d), ring(p1, w if w1 is None else w1, d if d1 is None else d1), caps)


def pyramid(name, base_centre, w, d, tip, base=False):
    """A 4-sided point (4 triangles, 6 with its base): glows, nozzles, warheads, antennae."""
    x, y, z = base_centre
    hw, hd = w / 2.0, d / 2.0
    # a base square perpendicular to the base->tip direction
    a = (mathutils.Vector(tip) - mathutils.Vector(base_centre)).normalized()
    ref = mathutils.Vector((1.0, 0.0, 0.0)) if abs(a.x) < 0.9 else mathutils.Vector((0.0, 0.0, 1.0))
    u = (ref - a * ref.dot(a)).normalized()
    v = a.cross(u)
    c = mathutils.Vector(base_centre)
    ring = [tuple(c + u * (sx * hw) + v * (sy * hd)) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    faces = [(i, (i + 1) % 4, 4) for i in range(4)]
    if base:
        faces.append((3, 2, 1, 0))
    return common.mesh(name, ring + [tuple(tip)], faces)


def quad(name, corners):
    """One flat face (2 triangles), front side counter-clockwise: a visor or a lens set on a surface."""
    return common.mesh(name, list(corners), [(0, 1, 2, 3)])


def visor(name, cx, y, z, w, h, lean=0.0):
    """A forward-facing (-Y) glowing quad, w wide and h tall, centred on (cx, y, z)."""
    hw, hh = w / 2.0, h / 2.0
    return quad(name, [(cx - hw, y - lean, z - hh), (cx + hw, y - lean, z - hh), (cx + hw, y + lean, z + hh), (cx - hw, y + lean, z + hh)])


def group(objs, name, pivot, **meta):
    """Puts every object in `objs` in art group `name`, with `pivot` (an object in objs) its pivot."""
    for obj in objs:
        if obj is pivot:
            common.art_group(obj, name, pivot=True, **meta)
        else:
            common.art_group(obj, name)
    return objs


def leg(m, name, hip, knee, foot, foot_w, foot_len, thigh_w, knee_w, thigh_mat="body", shin_mat="trim", shin_caps="t"):
    """A static leg in two blocks, 18 triangles: a thigh from the hip down to the knee (no caps, both
    ends hidden), and a shin that flares from the knee down into a foot flat on the ground, centred on
    `foot` (x, y). Returns [thigh, shin]."""
    thigh = beam(f"{name}_thigh", hip, knee, thigh_w, thigh_w * 1.1, knee_w, knee_w, caps="")
    kx, ky, kz = knee
    top = _rect(kx, ky, kz + knee_w * 0.3, knee_w, knee_w * 1.05)
    bottom = _rect(foot[0], foot[1], 0.0, foot_w, foot_len)
    shin = hexa(f"{name}_shin", bottom, top, caps=shin_caps)
    getattr(m, thigh_mat)(thigh)
    getattr(m, shin_mat)(shin)
    return [thigh, shin]


def pillar_leg(name, hip, foot, top_w, top_d, foot_w, foot_len, caps=""):
    """A stubby one-block leg, 8 triangles: from a top_w x top_d section at the hip down to a foot
    footprint on the ground centred on `foot` (x, y). Its top is inside the body."""
    top = _rect(hip[0], hip[1], hip[2], top_w, top_d)
    bottom = _rect(foot[0], foot[1], 0.0, foot_w, foot_len)
    return hexa(name, bottom, top, caps=caps)


def limb(name, points, sizes, tip=False, cap=False):
    """One mesh bent through `points`: a 4-sided ring (w, d from `sizes`) at each point, joined by
    sides, so a knee or an elbow is closed without an extra cap. With tip=True the last point is a
    single vertex (a claw, a toe, a nozzle); cap=True closes the last ring. 8 triangles a segment,
    4 for a tip. The first end is always open (it goes into the body)."""
    pts = [mathutils.Vector(p) for p in points]
    rings = []
    n_rings = len(pts) - 1 if tip else len(pts)
    for i in range(n_rings):
        if i == 0:
            a = pts[1] - pts[0]
        elif i == len(pts) - 1:
            a = pts[i] - pts[i - 1]
        else:
            a = (pts[i] - pts[i - 1]).normalized() + (pts[i + 1] - pts[i]).normalized()
        an = a.normalized()
        ref = mathutils.Vector((1.0, 0.0, 0.0))
        if abs(an.dot(ref)) > 0.95:
            ref = mathutils.Vector((0.0, 0.0, 1.0))
        u = (ref - an * ref.dot(an)).normalized()
        v = an.cross(u)
        w, d = sizes[i]
        rings.append([tuple(pts[i] + u * (sx * w / 2.0) + v * (sy * d / 2.0)) for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))])
    verts = [v for r in rings for v in r]
    faces = []
    for r in range(len(rings) - 1):
        b, t = 4 * r, 4 * (r + 1)
        faces += [(b + i, b + (i + 1) % 4, t + (i + 1) % 4, t + i) for i in range(4)]
    last = 4 * (len(rings) - 1)
    if tip:
        verts.append(tuple(pts[-1]))
        k = len(verts) - 1
        faces += [(last + i, last + (i + 1) % 4, k) for i in range(4)]
    elif cap:
        faces.append((last, last + 1, last + 2, last + 3))
    return common.mesh(name, verts, faces)


def walking_leg(name, parts, hip, mat, phase, swing, axis=(1.0, 0.0, 0.0), stride=None):
    """Joins a leg's blocks (built in world space, at location 0) into one mesh with one material,
    `mat` (a common.Materials paint, like m.trim), whose origin is the hip joint `hip`, and makes it its own art piece:
    kind="leg" swings it `swing` radians either way about `axis` through the hip while the unit
    walks. `stride` (studs a full cycle) defaults to 4 x hip height x sin(swing), which keeps the feet
    from visibly sliding. Returns the leg object."""
    import bpy

    verts, faces = [], []
    for part in parts:
        mw = part.matrix_world
        base = len(verts)
        verts += [tuple(mw @ v.co) for v in part.data.vertices]
        faces += [tuple(base + i for i in p.vertices) for p in part.data.polygons]
    for part in parts:
        mesh = part.data
        bpy.data.objects.remove(part, do_unlink=True)
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)
    leg = mat(common.mesh(name, verts, faces))
    common.set_pivot(leg, hip)
    if stride is None:
        stride = 4.0 * hip[2] * math.sin(swing)
    common.art_group(leg, name, pivot=True, kind="leg", axis=tuple(axis), swing=swing, phase=phase, stride=round(stride, 3))
    return leg
