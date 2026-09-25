"""Shared drawing for the HUD's command and weapon icons (icon_attack, icon_laser, ...): flat "vector" pictures
made of 2D shapes, to sit with the low-poly units, all in one colour. Each shape is a flat fill over a slightly bigger outline, standing
in Roblox's XY plane and facing +Z, and every layer is a sheet only THICKNESS deep, so seen from the front (and unlit,
Client.ui.art_icon's `flat`) nothing but the flat colours shows.

Every icon is the same fill colour over the same outline (PALETTE).

A shape is (outer, holes): a polygon in (x, up) and a list of polygons cut out of it, so rings, a recycling arrow
or a radiation sign are one shape each. Shapes may overlap; a picture is a list of layers drawn back to front, and
each layer's rim is drawn over the layers under it, so a detail laid on top of something is outlined against it.
Icons are drawn on a canvas about 4 across, centred on the origin (RECENTRE = False), and written to
src/shared/ui_art/.
"""

import math

MAX_TRIANGLES = 800

RIM = 0.15
# how deep each sheet is, and how far in front of its outline a fill sits and each layer of the last
THICKNESS = 0.03
FILL_LIFT = 0.03
LAYER_STEP = 0.08


def _rgb(r, g, b):
    return (r / 255, g / 255, b / 255, 1.0)


# Every icon is drawn in the same two colours: one fill, the HUD's text colour (stylesheets' $text), and the outline,
# which also draws what is inside an icon (a line round a part laid over another, or a dark cut-out).
OUTLINE = _rgb(22, 24, 30)
ICON = _rgb(236, 244, 252)

PALETTE = (OUTLINE, ICON)


# --- polygons -------------------------------------------------------------------------------------------------


def signed_area(polygon):
    n = len(polygon)
    return 0.5 * sum(polygon[i][0] * polygon[(i + 1) % n][1] - polygon[(i + 1) % n][0] * polygon[i][1] for i in range(n))


def ccw(polygon):
    return list(polygon) if signed_area(polygon) > 0 else list(reversed(polygon))


def offset(polygon, distance, max_miter=2.5):
    """A polygon grown outward by `distance` (shrunk if negative), mitred, each miter capped at max_miter times the
    distance so a sharp tip does not shoot off."""
    polygon = ccw(polygon)
    n = len(polygon)
    out = []
    for i in range(n):
        px, py = polygon[i - 1]
        cx, cy = polygon[i]
        nx, ny = polygon[(i + 1) % n]
        e1 = (cx - px, cy - py)
        e2 = (nx - cx, ny - cy)
        l1 = math.hypot(*e1) or 1e-9
        l2 = math.hypot(*e2) or 1e-9
        # outward normals of the two edges meeting here: right of the direction of travel, for CCW
        n1 = (e1[1] / l1, -e1[0] / l1)
        n2 = (e2[1] / l2, -e2[0] / l2)
        bx, by = n1[0] + n2[0], n1[1] + n2[1]
        bl = math.hypot(bx, by)
        if bl < 1e-9:
            out.append((cx + n1[0] * distance, cy + n1[1] * distance))
            continue
        bx, by = bx / bl, by / bl
        cos_half = max(bx * n1[0] + by * n1[1], 1e-6)
        miter = min(abs(distance) / cos_half, abs(distance) * max_miter)
        miter = math.copysign(miter, distance)
        out.append((cx + bx * miter, cy + by * miter))
    return out


def grow(shape, distance):
    """A shape grown by `distance`: its outline out, its holes in."""
    outer, holes = shape
    return (offset(outer, distance), [offset(hole, -distance) for hole in holes if _survives(hole, distance)])


def _survives(hole, distance):
    xs = [p[0] for p in hole]
    ys = [p[1] for p in hole]
    return min(max(xs) - min(xs), max(ys) - min(ys)) > distance * 2.2


def transform(shape, angle=0.0, scale=1.0, move=(0.0, 0.0), mirror_x=False):
    """A shape turned by `angle` degrees about the origin, scaled, mirrored across x = 0 if asked, then moved."""
    c = math.cos(math.radians(angle))
    s = math.sin(math.radians(angle))

    def point(p):
        x, y = p
        if mirror_x:
            x = -x
        x, y = x * scale, y * scale
        return (x * c - y * s + move[0], x * s + y * c + move[1])

    outer, holes = shape
    return ([point(p) for p in outer], [[point(p) for p in hole] for hole in holes])


# --- shapes ---------------------------------------------------------------------------------------------------


def poly(points, holes=()):
    return (list(points), [list(h) for h in holes])


def arc_points(cx, cy, r, a0, a1, segments):
    """Points along a circle from a0 to a1 degrees, both ends included."""
    return [
        (cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / segments)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / segments)))
        for i in range(segments + 1)
    ]


def circle_points(cx, cy, r, segments=24):
    return arc_points(cx, cy, r, 0.0, 360.0, segments)[:-1]


def circle(cx, cy, r, segments=24):
    return poly(circle_points(cx, cy, r, segments))


def ring(cx, cy, r_out, r_in, segments=28):
    return poly(circle_points(cx, cy, r_out, segments), [circle_points(cx, cy, r_in, segments)])


def arc_band(cx, cy, r_in, r_out, a0, a1, segments=10):
    """A piece of a ring between a0 and a1 degrees."""
    return poly(arc_points(cx, cy, r_out, a0, a1, segments) + list(reversed(arc_points(cx, cy, r_in, a0, a1, segments))))


def rect(x0, y0, x1, y1):
    return poly(((x0, y0), (x1, y0), (x1, y1), (x0, y1)))


def bar(a, b, width):
    """A straight stroke `width` thick from point a to point b, square ended."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    length = math.hypot(dx, dy)
    nx, ny = -dy / length * width / 2, dx / length * width / 2
    return poly(((a[0] + nx, a[1] + ny), (a[0] - nx, a[1] - ny), (b[0] - nx, b[1] - ny), (b[0] + nx, b[1] + ny)))


def rounded_rect(x0, y0, x1, y1, radius, segments=4):
    points = []
    for cx, cy, a in ((x1 - radius, y0 + radius, -90), (x1 - radius, y1 - radius, 0), (x0 + radius, y1 - radius, 90), (x0 + radius, y0 + radius, 180)):
        points += arc_points(cx, cy, radius, a, a + 90, segments)
    return poly(points)


def star(cx, cy, r_out, r_in, points=5, angle=90.0):
    out = []
    for i in range(points * 2):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(angle + i * 180.0 / points)
        out.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return poly(out)


def teardrop(cx, cy, r, length, angle=90.0, segments=14):
    """A drop: a round end of radius r at (cx, cy) and a point `length` away toward `angle` degrees."""
    a = math.radians(angle)
    tip = (cx + length * math.cos(a), cy + length * math.sin(a))
    half = math.degrees(math.acos(min(r / length, 0.999)))
    points = arc_points(cx, cy, r, angle + half, angle + 360.0 - half, segments)
    return poly(points + [tip])


def ellipse_points(cx, cy, rx, ry, a0=0.0, a1=360.0, segments=20):
    return [
        (cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / segments)), cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / segments)))
        for i in range(segments + 1)
    ]


def ellipse_ring(cx, cy, rx, ry, width, segments=20):
    return poly(ellipse_points(cx, cy, rx, ry, segments=segments)[:-1], [ellipse_points(cx, cy, rx - width, ry - width, segments=segments)[:-1]])


def ellipse_band(cx, cy, rx, ry, width, a0, a1, segments=10):
    """A piece of an ellipse ring between a0 and a1 degrees."""
    return poly(ellipse_points(cx, cy, rx, ry, a0, a1, segments) + list(reversed(ellipse_points(cx, cy, rx - width, ry - width, a0, a1, segments))))


def square(cx, cy, size, angle=0.0):
    return transform(rect(-size / 2, -size / 2, size / 2, size / 2), angle=angle, move=(cx, cy))


def mirrored(points):
    """A symmetric outline from its right half, listed top to bottom along x >= 0 (both ends on x = 0)."""
    return list(points) + [(-x, y) for x, y in reversed(points[1:-1])]


def place(shapes, shift=(0.0, 0.0), angle=0.0, scale=1.0):
    """Shapes moved by `shift`, then scaled and turned `angle` degrees about the origin."""
    return [transform(transform(shape, move=shift), angle=angle, scale=scale) for shape in shapes]


def wave(x0, x1, y, amplitude, wavelength, width, segments=24, phase=0.0):
    """A wavy stroke along y from x0 to x1."""
    xs = [x0 + (x1 - x0) * i / segments for i in range(segments + 1)]
    mid = [y + amplitude * math.sin(2 * math.pi * (x - x0) / wavelength + phase) for x in xs]
    return poly([(x, m - width / 2) for x, m in zip(xs, mid)] + [(x, m + width / 2) for x, m in reversed(list(zip(xs, mid)))])


# a lightning bolt, top right to bottom left, about 2 across and 3.9 high
BOLT = ((0.2, 1.9), (1.05, 1.9), (0.4, 0.45), (1.05, 0.45), (-0.6, -1.95), (-0.1, -0.2), (-0.8, -0.2))



# --- building -------------------------------------------------------------------------------------------------


def _mat_name(color):
    return "icon_" + "".join(f"{round(c * 255):02x}" for c in color[:3])


def _slab(name, shapes, front, color):
    """The shapes (outlines with holes, which must not overlap one another) as one standing sheet THICKNESS deep, its
    face at `front` toward the viewer (Blender -Y), with its unseen back face dropped."""
    import bmesh
    import bpy

    from . import common

    back = front - THICKNESS
    curve = bpy.data.curves.new(f"{name}_curve", type="CURVE")
    curve.dimensions = "2D"
    curve.fill_mode = "BOTH"
    curve.extrude = (front - back) / 2.0
    for outer, holes in shapes:
        for ring_points, want_ccw in [(outer, True)] + [(h, False) for h in holes]:
            ring_points = ccw(ring_points)
            if not want_ccw:
                ring_points = list(reversed(ring_points))
            spline = curve.splines.new("POLY")
            spline.points.add(len(ring_points) - 1)
            for point, (x, y) in zip(spline.points, ring_points):
                point.co = (x, y, 0.0, 1.0)
            spline.use_cyclic_u = True
    holder = bpy.data.objects.new(f"{name}_holder", curve)
    bpy.context.collection.objects.link(holder)
    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(holder.evaluated_get(depsgraph))
    bpy.data.objects.remove(holder, do_unlink=True)
    bpy.data.curves.remove(curve)

    middle = (front + back) / 2.0
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    # curve space (x, y, extrude z) -> standing up facing the viewer: Blender (x, -(z + middle), y)
    for v in bm.verts:
        x, y, z = v.co
        v.co = (x, -(z + middle), y)
    bm.normal_update()
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    unseen = [f for f in bm.faces if f.normal.y > 0.99]
    bmesh.ops.delete(bm, geom=unseen, context="FACES_ONLY")
    bm.to_mesh(mesh)
    bm.free()

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    common.apply_material(obj, _mat_name(color), color, roughness=0.45)
    return obj


def layer(shapes, color, rim=OUTLINE, rim_width=RIM):
    """A layer of the picture: `shapes` filled with `color`, outlined in `rim` (None for no outline)."""
    assert color in PALETTE and (rim is None or rim in PALETTE), "icons keep to icon_common.PALETTE"
    return {"shapes": list(shapes), "color": color, "rim": rim, "rim_width": rim_width}


def colours(layers):
    """Every colour the layers use, outline included."""
    used = set()
    for spec in layers:
        used.add(spec["color"])
        if spec["rim"] is not None:
            used.add(spec["rim"])
    return used


def build(prefix, layers):
    """The layers, back to front, as standing sheets, each nearer the viewer than the last. Everything is `base`."""
    assert colours(layers) <= set(PALETTE), f"icon {prefix} uses a colour of its own"
    objs = []
    for index, spec in enumerate(layers):
        lift = index * LAYER_STEP
        # a slab each: a curve's fill cuts one outline out of any other it overlaps
        for n, shape in enumerate(spec["shapes"]):
            if spec["rim"] is not None:
                rimmed = grow(shape, spec["rim_width"])
                objs.append(_slab(f"{prefix}_{index}_{n}_rim", [rimmed], lift, spec["rim"]))
            objs.append(_slab(f"{prefix}_{index}_{n}_fill", [shape], lift + FILL_LIFT, spec["color"]))
    return objs
