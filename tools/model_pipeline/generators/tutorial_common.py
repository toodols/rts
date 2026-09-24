"""Shared shapes for the tutorial's UI icons (tutorial_wasd, tutorial_arrows, tutorial_mouse, tutorial_cursor,
tutorial_check, tutorial_cross): keycaps with glyphs, extruded outlines and standing slabs.

These are not units: they are shown a few at a time in HUD ViewportFrames, so each may spend up to MAX_TRIANGLES,
and each places its own origin (RECENTRE = False in the generator). Their art modules go to src/shared/ui_art/
(build with -LuauOut), never src/shared/art/, which is keyed by unit def.

Blender is Z-up; the art module is Roblox Y-up, (x, y, z) -> (x, z, -y). So a Roblox +Z (toward the UI camera) is
Blender -Y, and "up" on a key's face (Roblox -Z, away from the viewer) is Blender +Y: text laid in Blender's XY
plane reads upright from the camera as it is.
"""

import math
from pathlib import Path

import bmesh
import bpy

from . import common

MAX_TRIANGLES = 800

CAP_COLOR = (0.86, 0.86, 0.83, 1.0)
GLYPH_COLOR = (0.10, 0.10, 0.12, 1.0)

KEY_WIDTH = 2.0
KEY_PITCH = 2.24  # centre to centre: a small gap between caps
CAP_HEIGHT = 0.62
CHAMFER_HEIGHT = 0.12
KEY_TOP = CAP_HEIGHT + CHAMFER_HEIGHT
GLYPH_DEPTH = 0.06

# the inverted-T: (column, row) of each key, row 0 at the back (Blender +Y), row 1 in front
INVERTED_T = ((0, 0), (-1, 1), (0, 1), (1, 1))

FONT_CANDIDATES = (
    Path("C:/Windows/Fonts/ariblk.ttf"),  # Arial Black: the chunkiest, best read small
    Path("C:/Windows/Fonts/arialbd.ttf"),
)


def mat(obj, name, color, roughness=0.5, emission=0.0):
    common.apply_material(obj, name, color, roughness=roughness, emission=emission)
    return obj


def key_centre(column, row):
    """Blender (x, y) of a key in the inverted-T, the whole cluster centred on the origin."""
    return (column * KEY_PITCH, (0.5 - row) * KEY_PITCH)


def keycap(name, x, y):
    """A chunky keycap standing base-down at (x, y): tapered sides, then a narrow chamfer up to its flat top at
    KEY_TOP. Its first piece is the one to pivot on (its location is the key's centre on the ground)."""
    body = common.tapered_box(f"{name}_cap", KEY_WIDTH, KEY_WIDTH, CAP_HEIGHT, 1.8, 1.8, origin=(x, y, 0.0))
    chamfer = common.tapered_box(
        f"{name}_top", 1.8, 1.8, CHAMFER_HEIGHT, 1.56, 1.56, origin=(x, y, CAP_HEIGHT)
    )
    common.drop_bottom(body)
    common.drop_bottom(chamfer)
    for obj in (body, chamfer):
        mat(obj, "key_cap", CAP_COLOR, roughness=0.6)
    return [body, chamfer]


def drop_down_faces(obj):
    """Deletes every face pointing straight down (a glyph's underside, lying on its cap)."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.normal_update()
    hidden = [f for f in bm.faces if f.normal.z < -0.99]
    bmesh.ops.delete(bm, geom=hidden, context="FACES_ONLY")
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def _font():
    for path in FONT_CANDIDATES:
        if path.is_file():
            return bpy.data.fonts.load(str(path), check_existing=True)
    return None  # Blender's built-in font


def text_glyph(name, text, size, x, y, z, depth=GLYPH_DEPTH, resolution=2):
    """`text` as a raised mesh glyph lying on the XY plane, its bounds centred on (x, y), its underside at z:
    reads upright from the UI camera (see the module docstring)."""
    curve = bpy.data.curves.new(f"{name}_text", type="FONT")
    curve.body = text
    font = _font()
    if font is not None:
        curve.font = font
    curve.size = size
    curve.align_x = "CENTER"
    curve.align_y = "CENTER"
    curve.resolution_u = resolution
    curve.extrude = depth / 2.0  # extrudes both ways
    curve.fill_mode = "BOTH"
    holder = bpy.data.objects.new(f"{name}_text", curve)
    bpy.context.collection.objects.link(holder)

    depsgraph = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(holder.evaluated_get(depsgraph))
    bpy.data.objects.remove(holder, do_unlink=True)
    bpy.data.curves.remove(curve)

    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    bm = bmesh.new()
    bm.from_mesh(mesh)
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    xs = [v.co.x for v in bm.verts]
    ys = [v.co.y for v in bm.verts]
    zs = [v.co.z for v in bm.verts]
    shift = ((min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0, min(zs))
    bmesh.ops.translate(bm, vec=(-shift[0], -shift[1], -shift[2]), verts=bm.verts)
    bm.to_mesh(mesh)
    bm.free()
    obj.location = (x, y, z)
    drop_down_faces(obj)
    return obj


def prism(name, polygon, z0, height, origin=(0.0, 0.0), bottom=False):
    """A flat 2D polygon (counter-clockwise, Blender XY) extruded straight up from z0 by height: a top face and
    side walls, and a bottom only if asked."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    low = [bm.verts.new((px, py, z0)) for px, py in polygon]
    high = [bm.verts.new((px, py, z0 + height)) for px, py in polygon]
    bm.faces.new(high)
    if bottom:
        bm.faces.new(list(reversed(low)))
    n = len(polygon)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((low[i], low[j], high[j], high[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = (origin[0], origin[1], 0.0)
    return obj


def standing_slab(name, polygon, front, back):
    """A 2D polygon (counter-clockwise, in (x, up)) as a slab standing in Blender's XZ plane, i.e. Roblox's XY
    plane, facing the viewer: its face toward Roblox +Z at Blender y = -front, its back at y = -back (front > back
    brings it nearer the viewer)."""
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    near = [bm.verts.new((px, -front, pz)) for px, pz in polygon]
    far = [bm.verts.new((px, -back, pz)) for px, pz in polygon]
    bm.faces.new(near)
    bm.faces.new(list(reversed(far)))
    n = len(polygon)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((near[i], near[j], far[j], far[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def offset_polygon(polygon, distance, max_miter=3.0):
    """A counter-clockwise polygon grown outward by `distance` (mitred corners, each miter capped at max_miter
    times the distance so a sharp tip does not shoot off)."""
    n = len(polygon)
    out = []
    for i in range(n):
        px, py = polygon[i - 1]
        cx, cy = polygon[i]
        nx, ny = polygon[(i + 1) % n]
        # outward normals of the two edges meeting here (right of the direction of travel, for CCW)
        e1 = (cx - px, cy - py)
        e2 = (nx - cx, ny - cy)
        l1 = math.hypot(*e1)
        l2 = math.hypot(*e2)
        n1 = (e1[1] / l1, -e1[0] / l1)
        n2 = (e2[1] / l2, -e2[0] / l2)
        bx, by = n1[0] + n2[0], n1[1] + n2[1]
        bl = math.hypot(bx, by)
        if bl < 1e-9:
            out.append((cx + n1[0] * distance, cy + n1[1] * distance))
            continue
        bx, by = bx / bl, by / bl
        cos_half = bx * n1[0] + by * n1[1]
        miter = min(distance / max(cos_half, 1e-6), distance * max_miter)
        out.append((cx + bx * miter, cy + by * miter))
    return out


def signed_area(polygon):
    return 0.5 * sum(
        polygon[i][0] * polygon[(i + 1) % len(polygon)][1] - polygon[(i + 1) % len(polygon)][0] * polygon[i][1]
        for i in range(len(polygon))
    )


def ccw(polygon):
    return list(polygon) if signed_area(polygon) > 0 else list(reversed(polygon))


def outlined_badge(prefix, polygon, fill_color, rim_color, rim=0.16, depth=0.5, group=None):
    """A chunky standing icon: `polygon` (in (x, up)) as a bright slab over a darker, slightly bigger rim slab
    behind it, both facing Roblox +Z. Returns [rim, fill]."""
    polygon = ccw(polygon)
    rim_obj = standing_slab(f"{prefix}_rim", offset_polygon(polygon, rim), depth * 0.55, -depth * 0.45)
    fill_obj = standing_slab(f"{prefix}_fill", polygon, depth * 0.5 + 0.06, -depth * 0.3)
    mat(rim_obj, f"{prefix}_rim", rim_color, roughness=0.5)
    mat(fill_obj, f"{prefix}_fill", fill_color, roughness=0.4)
    objs = [rim_obj, fill_obj]
    if group is not None:
        for obj in objs:
            common.art_group(obj, group)
    return objs


def key_cluster(glyph_for):
    """The four keys of an inverted-T, each its own art group (keycap + glyph), pivoting on its centre on the
    ground. `glyph_for(index, x, y, z)` makes key `index`'s glyph lying on its top at height z and returns
    (group_name, glyph_object)."""
    objs = []
    for index, (column, row) in enumerate(INVERTED_T):
        x, y = key_centre(column, row)
        group, glyph = glyph_for(index, x, y, KEY_TOP)
        cap = keycap(group, x, y)
        mat(glyph, "key_glyph", GLYPH_COLOR, roughness=0.4)
        # the cap's body sits at the key's centre on the ground: the group pivots there
        common.art_group(cap[0], group, pivot=True)
        for obj in cap[1:] + [glyph]:
            common.art_group(obj, group)
        objs.extend(cap + [glyph])
    return objs
