"""Shared shapes for the tutorial's UI icons (tutorial_wasd, tutorial_arrows, tutorial_mouse, tutorial_cursor,
tutorial_check, tutorial_cross): keycaps with glyphs and extruded outlines (the check, cross and cursor are
icon.badge).

These are not units: they are shown a few at a time in HUD ViewportFrames, so each is a "hud" model, which may spend
more triangles and places its own origin, and whose art module goes to src/shared/ui_art/.

Blender is Z-up; the art module is Roblox Y-up, (x, y, z) -> (x, z, -y). So a Roblox +Z (toward the UI camera) is
Blender -Y, and "up" on a key's face (Roblox -Z, away from the viewer) is Blender +Y: text laid in Blender's XY
plane reads upright from the camera as it is.
"""

import hashlib
from pathlib import Path

import bmesh
import bpy

from . import common
from . import palette


KEY_WIDTH = 2.0
KEY_PITCH = 2.24  # centre to centre: a small gap between caps
CAP_HEIGHT = 0.62
CHAMFER_HEIGHT = 0.12
KEY_TOP = CAP_HEIGHT + CHAMFER_HEIGHT
GLYPH_DEPTH = 0.06

# the inverted-T: (column, row) of each key, row 0 at the back (Blender +Y), row 1 in front
INVERTED_T = ((0, 0), (-1, 1), (0, 1), (1, 1))

# The keys' glyphs are Arial Black, the chunkiest, best read small. Its licence does not let it be kept in the repository,
# and an open font instead would change every glyph's mesh (and so need re-uploading), so the build reads it from the
# system, and only this very file (its sha256): another font, or another version of it, would build other meshes.
FONT_PATH = Path("C:/Windows/Fonts/ariblk.ttf")
FONT_SHA256 = "10df702864b1f89cb29ba0d6b97c04228338d16807e13e8d8c74b91aba5e5f23"


def key_centre(column, row):
    """Blender (x, y) of a key in the inverted-T, the whole cluster centred on the origin."""
    return (column * KEY_PITCH, (0.5 - row) * KEY_PITCH)


def keycap(name, x, y):
    """A chunky keycap standing base-down at (x, y): tapered sides, then a narrow chamfer up to its flat top at
    KEY_TOP. Its first piece is the one to pivot on (its location is the key's centre on the ground)."""
    body = common.block(f"{name}_cap", KEY_WIDTH, KEY_WIDTH, CAP_HEIGHT, top=(1.8, 1.8), origin=(x, y, 0.0))
    chamfer = common.block(f"{name}_top", 1.8, 1.8, CHAMFER_HEIGHT, top=(1.56, 1.56), origin=(x, y, CAP_HEIGHT))
    common.drop_bottom(body)
    common.drop_bottom(chamfer)
    for obj in (body, chamfer):
        common.paint(obj, palette.KEYCAP)
    return [body, chamfer]


def _font():
    """FONT_PATH, loaded; the build stops if it is not there, or not the file the glyphs were built from."""
    if not FONT_PATH.is_file():
        raise SystemExit(f"the tutorial's keys need Arial Black at {FONT_PATH}")
    if hashlib.sha256(FONT_PATH.read_bytes()).hexdigest() != FONT_SHA256:
        raise SystemExit(f"{FONT_PATH} is not the Arial Black the keys' glyphs were built from (FONT_SHA256)")
    return bpy.data.fonts.load(str(FONT_PATH), check_existing=True)


def text_glyph(name, text, size, x, y, z, depth=GLYPH_DEPTH, resolution=2):
    """`text` as a raised mesh glyph lying on the XY plane, its bounds centred on (x, y), its underside at z:
    reads upright from the UI camera (see the module docstring)."""
    curve = bpy.data.curves.new(f"{name}_text", type="FONT")
    curve.body = text
    curve.font = _font()
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
    common.drop_facing(obj, (0.0, 0.0, -1.0), threshold=0.99)
    return obj


def prism(name, polygon, z0, height, origin=(0.0, 0.0), bottom=False):
    """A flat 2D polygon (counter-clockwise, Blender XY) extruded straight up from z0 by height: a top face and
    side walls, and a bottom only if asked."""
    n = len(polygon)
    verts = [(px, py, z0) for px, py in polygon] + [(px, py, z0 + height) for px, py in polygon]
    faces = [tuple(range(n, 2 * n))]
    if bottom:
        faces.append(tuple(reversed(range(n))))
    faces += [(i, (i + 1) % n, n + (i + 1) % n, n + i) for i in range(n)]
    return common.mesh(name, verts, faces, (origin[0], origin[1], 0.0), recalc_normals=True)


def key_cluster(glyph_for):
    """The four keys of an inverted-T, each its own art group (keycap + glyph), pivoting on its centre on the
    ground. `glyph_for(index, x, y, z)` makes key `index`'s glyph lying on its top at height z and returns
    (group_name, glyph_object)."""
    objs = []
    for index, (column, row) in enumerate(INVERTED_T):
        x, y = key_centre(column, row)
        group, glyph = glyph_for(index, x, y, KEY_TOP)
        cap = keycap(group, x, y)
        common.paint(glyph, palette.KEY_GLYPH)
        # the cap's body sits at the key's centre on the ground: the group pivots there
        common.art_group(cap[0], group, pivot=True)
        for obj in cap[1:] + [glyph]:
            common.art_group(obj, group)
        objs.extend(cap + [glyph])
    return objs
