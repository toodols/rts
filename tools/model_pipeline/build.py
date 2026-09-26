"""Headless Blender entry point for the procedural model pipeline. Run it through build.ps1, or Blender itself (bpy
only exists inside Blender):

    blender --background --python tools/model_pipeline/build.py -- grunt [more generators...]
    blender --background --python tools/model_pipeline/build.py -- --all
    blender --background --python tools/model_pipeline/build.py -- --stale

Everything after the lone `--` is this script's own argv; Blender strips its own flags before it.

Each generator (generators/<name>.py) builds one model and declares its CATEGORY, which says where its art module
goes, what it may spend and how it is placed (manifest.CATEGORIES). One that dresses a def declares DEF, the def's name, and
gets that def's collider and colour from the game (tools/game_data.py) in its params, as `collider` and `color`; a unit
with a capsule collider is then stretched to fill its BAR collision volume, and every model of a def is checked
against its collider (see `fit_problems`). A generator may declare what it is allowed past those checks, each with its
reason: ENVELOPE, how far it may reach instead of its collider ({"width": ..., "length": ..., "height": ...}, studs,
any of them), and TRIANGLES, the triangles it may spend instead of its category's.

A build writes the model's art module (art_format.py), its upload file (build/<name>_art.glb: the meshes not on
Roblox yet, for roblox/upload_art.py), a preview render (build/<name>.png) and its entry in built.json.
"""

import argparse
import hashlib
import importlib
import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
import mathutils

PIPELINE_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PIPELINE_ROOT))
sys.path.insert(0, str(PIPELINE_ROOT.parent))

import art_format  # noqa: E402
import game_data  # noqa: E402
import manifest  # noqa: E402
import turret_mounts  # noqa: E402
from generators.shared import common  # noqa: E402

# Edges sharper than this are split before export, so each side keeps its own vertex normal: Roblox would otherwise
# average normals across shared vertices and round a box's corners off.
SHARP_EDGE_DEGREES = 40.0
# How much more one axis of a unit may be stretched than the one stretched least, so that filling its collision
# volume widens a long tank or heightens a flat one without turning it into a cube.
MAX_STRETCH = 1.35
# How far a model may reach past its collision volume before the fit check calls it a misfit, in studs.
FIT_TOLERANCE = 1e-3


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("generators", nargs="*", help="generators to build, by name (generators/<name>.py)")
    parser.add_argument("--all", action="store_true", help="build every generator")
    parser.add_argument("--stale", action="store_true", help="build every generator whose module is out of date")
    parser.add_argument("--list", action="store_true", help="list the generators and exit")
    parser.add_argument("--params", default="{}", help="JSON object merged into generate(params)")
    parser.add_argument("--no-render", action="store_true", help="skip the preview render")
    parser.add_argument(
        "--out-dir",
        default=None,
        help="write the art modules here instead of the game's source, leaving built.json alone (to compare builds)",
    )
    parser.add_argument("--game-root", default=None, help="read the game's numbers from another checkout")
    return parser.parse_args(argv)


def clear_scene():
    """Back to an empty file, so nothing (a material cached by name above all) carries from one build to the next."""
    bpy.ops.wm.read_factory_settings(use_empty=True)


def triangle_count(objects):
    return sum(len(p.vertices) - 2 for obj in objects for p in obj.data.polygons)


def material_of(obj):
    """(name, rgba color, glows, team) for an object's first material. An emissive material (apply_material's
    `emission`) glows, which becomes Neon in Roblox: the only way a part there actually lights up. A `team` one
    (apply_material's `team`) takes its team's colour in the game."""
    if not obj.data.materials or obj.data.materials[0] is None:
        return "", (1.0, 1.0, 1.0, 1.0), False, False
    mat = obj.data.materials[0]
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    color = tuple(bsdf.inputs["Base Color"].default_value)
    glows = bsdf.inputs["Emission Strength"].default_value > 0.0
    return mat.name, color, glows, bool(mat.get("art_team", False))


def world_triangles(obj):
    """An object's triangulated mesh in world space, Roblox Y-up: (vertices, triangles). Sharp edges are split
    first (see SHARP_EDGE_DEGREES)."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    sharp = math.radians(SHARP_EDGE_DEGREES)
    bm.normal_update()
    edges = [e for e in bm.edges if len(e.link_faces) == 2 and e.calc_face_angle(0.0) > sharp]
    bmesh.ops.split_edges(bm, edges=edges)
    # fixed diagonals, not "beauty": beauty settles near-ties between a quad's two diagonals differently from one run
    # to the next, which would change a mesh's hash (and so re-upload it) without changing how it looks
    bmesh.ops.triangulate(bm, faces=bm.faces, quad_method="FIXED", ngon_method="EAR_CLIP")
    bm.transform(obj.matrix_world)
    bm.verts.index_update()
    # Blender is Z-up; Roblox (like glTF) is Y-up: (x, z, -y).
    verts = [(v.co.x, v.co.z, -v.co.y) for v in bm.verts]
    triangles = [tuple(v.index for v in f.verts) for f in bm.faces]
    bm.free()
    return verts, triangles


def to_roblox(location):
    x, y, z = location
    return (x, z, -y)


def collect_groups(objects):
    """The model's rigid pieces, by the `art_group` a generator set on each object (common.art_group): "base"
    for anything that set none. A piece's pivot is the location of its object marked `art_pivot`, or the model's
    origin; the rest of what the generator set (art_format.META_FIELDS) describes how it moves."""
    groups = {}
    for obj in objects:
        name = obj.get("art_group", "base")
        group = groups.setdefault(name, {"objects": [], "fields": {"pivot": (0.0, 0.0, 0.0)}})
        group["objects"].append(obj)
        if obj.get("art_pivot"):
            group["fields"]["pivot"] = to_roblox(obj.location)
        for key, kind, _ in art_format.META_FIELDS:
            if f"art_{key}" in obj:
                value = obj[f"art_{key}"]
                # a direction the generator gave in Blender's axes
                group["fields"][key] = to_roblox(value) if kind == "point" else value
    return groups


def art_parts(objects):
    """(groups, parts): the model's rigid pieces, and one entry per mesh of them, each with its vertices centred
    on its own bounds, its size, its offset from its piece's pivot, and a hash of its geometry that names it on
    Roblox once it is uploaded."""
    groups = collect_groups(objects)
    parts = []
    for group_name, group in groups.items():
        by_material = {}
        for obj in group["objects"]:
            mat_name, color, glows, team = material_of(obj)
            entry = by_material.setdefault(
                mat_name, {"color": color, "glows": glows, "team": team, "verts": [], "tris": []}
            )
            verts, tris = world_triangles(obj)
            base = len(entry["verts"])
            entry["verts"].extend(verts)
            entry["tris"].extend((a + base, b + base, c + base) for a, b, c in tris)

        px, py, pz = group["fields"]["pivot"]
        for entry in by_material.values():
            verts = entry["verts"]
            lo = [min(v[i] for v in verts) for i in range(3)]
            hi = [max(v[i] for v in verts) for i in range(3)]
            centre = [(lo[i] + hi[i]) / 2 for i in range(3)]
            packed_verts = "|".join(",".join(art_format.lua_number(v[i] - centre[i]) for i in range(3)) for v in verts)
            # in a canonical order, each rotated to start at its lowest vertex (which keeps its winding): the order
            # Blender hands faces back in can vary between runs, and should not change the hash
            tris = sorted(min((t, t[1:] + t[:1], t[2:] + t[:2])) for t in entry["tris"])
            packed_tris = "|".join(f"{a},{b},{c}" for a, b, c in tris)
            parts.append({
                "group": group_name,
                "color": entry["color"],
                "glows": entry["glows"],
                "team": entry["team"],
                "offset": (centre[0] - px, centre[1] - py, centre[2] - pz),
                "size": tuple(hi[i] - lo[i] for i in range(3)),
                "centred": [tuple(v[i] - centre[i] for i in range(3)) for v in verts],
                "tris": tris,
                "hash": hashlib.sha1(f"{packed_verts}#{packed_tris}".encode("utf-8")).hexdigest()[:16],
            })
    return groups, parts


def muzzle_of(group_name, parts):
    """Where a turret's art puts its muzzle, relative to its pivot and at rest (Roblox axes, facing +Z): the point of
    its meshes that reaches furthest forward, which is the tip of its barrel, launcher or glowing muzzle."""
    best = None
    for part in parts:
        if part["group"] != group_name:
            continue
        ox, oy, oz = part["offset"]
        for x, y, z in part["centred"]:
            point = (ox + x, oy + y, oz + z)
            if best is None or point[2] > best[2]:
                best = point
    return best


def export_art(groups, parts, out_path, model_name, meshes):
    """The model as its art module (art_format.py), which the client dresses its entities from (src/client/art.luau).

    Each rigid piece (see collect_groups) becomes one MeshPart per material: everything that shares a color and
    moves together is one mesh. Each part's `offset` places the centre of its mesh's bounds relative to its piece's
    pivot, which is relative to the model's origin: the middle of its footprint, on the ground, facing +Z. A part
    names its uploaded mesh (`meshes`, roblox/uploads.json's assets) by asset id; one whose mesh is not uploaded yet has
    only its hash, and the model needs uploading (roblox/upload_art.py) before the game can show it."""
    group_fields = {name: group["fields"] for name, group in groups.items()}
    part_fields = []
    for part in parts:
        mesh = meshes.get(part["hash"])
        part_fields.append({
            "group": part["group"],
            "color": part["color"],
            "offset": part["offset"],
            "size": part["size"],
            "hash": part["hash"],
            "neon": part["glows"],
            "team": part["team"],
            "mesh": mesh["id"] if mesh is not None else None,
        })
    text = art_format.module_text(model_name, group_fields, part_fields)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(text, encoding="utf-8")
    pending = sum(1 for part in part_fields if part["mesh"] is None)
    print(f"wrote {out_path} ({len(parts)} parts, {pending} waiting for an upload)")
    return text


def new_object(name):
    obj = bpy.data.objects.new(name, bpy.data.meshes.new(name))
    bpy.context.collection.objects.link(obj)
    return obj


def export_upload_glb(parts, out_path):
    """`parts`' meshes as one node each of a .glb, named by its hash and centred as the art has it, for
    roblox/upload_art.py to upload as one Model. Uploading makes one mesh asset per node, which is what the art
    module then refers to."""
    made = []
    for part in parts:
        obj = new_object(part["hash"])
        bm = bmesh.new()
        # back from Roblox's (x, y, z) to Blender's: the glTF export's Y-up conversion then gives (x, y, z) again
        verts = [bm.verts.new((x, -z, y)) for x, y, z in part["centred"]]
        for a, b, c in part["tris"]:
            try:
                # smooth: the sharp edges are already split, so what shares a vertex is meant to be smooth
                bm.faces.new((verts[a], verts[b], verts[c])).smooth = True
            except ValueError:
                pass  # a face repeated after an edge split; one copy is enough
        bm.to_mesh(obj.data)
        bm.free()
        made.append(obj)

    bpy.ops.object.select_all(action="DESELECT")
    for obj in made:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = made[0]
    out_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(filepath=str(out_path), export_format="GLB", use_selection=True, export_yup=True)
    print(f"wrote {out_path} ({len(made)} meshes)")
    for obj in made:
        bpy.data.objects.remove(obj, do_unlink=True)


def render_preview(objects, out_path):
    """A quick three-quarter-view PNG so a build can be visually reviewed without opening
    Blender or Studio -- the point of the build/look/tweak loop for a generator."""
    corners = []
    for obj in objects:
        for corner in obj.bound_box:
            corners.append(obj.matrix_world @ mathutils.Vector(corner))
    min_v = mathutils.Vector((min(c.x for c in corners), min(c.y for c in corners), min(c.z for c in corners)))
    max_v = mathutils.Vector((max(c.x for c in corners), max(c.y for c in corners), max(c.z for c in corners)))
    center = (min_v + max_v) / 2
    size = max((max_v - min_v).length, 0.5)
    distance = size * 1.6

    cam_data = bpy.data.cameras.new("PreviewCam")
    cam_data.lens = 50
    cam_obj = bpy.data.objects.new("PreviewCam", cam_data)
    bpy.context.collection.objects.link(cam_obj)
    cam_obj.location = center + mathutils.Vector((distance * 0.75, -distance * 0.95, distance * 0.65))
    direction = center - cam_obj.location
    cam_obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = cam_obj

    sun_data = bpy.data.lights.new("PreviewSun", type="SUN")
    sun_data.energy = 3.0
    sun_data.angle = math.radians(5)
    sun_obj = bpy.data.objects.new("PreviewSun", sun_data)
    sun_obj.rotation_euler = (math.radians(55), 0.0, math.radians(35))
    bpy.context.collection.objects.link(sun_obj)

    fill_data = bpy.data.lights.new("PreviewFill", type="AREA")
    fill_data.energy = size * 120
    fill_data.size = size * 1.5
    fill_obj = bpy.data.objects.new("PreviewFill", fill_data)
    fill_obj.location = center + mathutils.Vector((-distance, -distance * 0.4, distance * 0.5))
    bpy.context.collection.objects.link(fill_obj)

    world = bpy.data.worlds.get("World") or bpy.data.worlds.new("World")
    bpy.context.scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    if bg is not None:
        bg.inputs[0].default_value = (0.08, 0.09, 0.11, 1.0)

    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.render.resolution_x = 900
    scene.render.resolution_y = 900
    scene.render.film_transparent = False
    # Blender's default AgX view desaturates bright colors (gold reads as cream, a glowing orb as
    # off-white); Standard keeps them close to the flat Color3 each part gets in Roblox.
    scene.view_settings.view_transform = "Standard"
    scene.render.filepath = str(out_path)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.render.render(write_still=True)
    print(f"wrote {out_path}")


def bar_volume(collider):
    """A capsule collider's BAR collision volume, (width, length, height) in Blender's (x, y, z) studs."""
    return (collider["width"], collider["length"], collider["height"])


def world_points(obj):
    """An object's vertices in world space, and for a walking leg also where they swing to at either end of its
    stride (turned its `swing` either way about its hip), which is as far as it reaches while the unit walks."""
    points = [obj.matrix_world @ v.co for v in obj.data.vertices]
    if obj.get("art_kind") != "leg":
        return points
    pivot = obj.location.copy()
    axis = mathutils.Vector(tuple(obj["art_axis"]))
    swung = []
    for sign in (1.0, -1.0):
        turn = mathutils.Matrix.Rotation(sign * obj["art_swing"], 4, axis)
        swung += [pivot + turn @ (p - pivot) for p in points]
    return points + swung


def world_bounds(objects, swinging=False):
    """The bounds of `objects` in world space, (lo, hi); with `swinging`, of every walking leg's whole stride."""
    lo = [math.inf] * 3
    hi = [-math.inf] * 3
    for obj in objects:
        points = world_points(obj) if swinging else [obj.matrix_world @ v.co for v in obj.data.vertices]
        for w in points:
            for i in range(3):
                lo[i] = min(lo[i], w[i])
                hi[i] = max(hi[i], w[i])
    return lo, hi


def fill_volume(objects, volume):
    """Scales a unit up to fill its BAR collision volume, which is the size BAR draws it at: a model designed to fit
    inside the collider's cylinder is a rectangle inscribed in its circle, well short of the volume's own width and
    length. Each axis is stretched as far as it takes to fill, but never shrunk and never more than MAX_STRETCH times
    the axis stretched least, so the design keeps its proportions. The model is scaled about its origin (the middle
    of its footprint, on the ground) and every rotation is baked into its mesh, so each piece keeps its pivot."""
    lo, hi = world_bounds(objects)
    # the footprint straddles the origin, so fill by the reach on each side, and the height from the ground
    reach = [max(abs(lo[0]), abs(hi[0])) * 2, max(abs(lo[1]), abs(hi[1])) * 2, hi[2]]
    wanted = [max(volume[i] / reach[i], 1.0) if reach[i] > 1e-6 else 1.0 for i in range(3)]
    least = min(wanted)
    scale = [min(s, least * MAX_STRETCH) for s in wanted]
    if all(abs(s - 1.0) < 1e-3 for s in scale):
        return
    sx, sy, sz = scale
    for obj in objects:
        world = obj.matrix_world.copy()
        location = world.translation
        new_location = mathutils.Vector((location.x * sx, location.y * sy, location.z * sz))
        # a wheel goes where the scaled model puts its hub but keeps its own shape round, scaled by the height both
        # ways across its face, or it would wobble as it rolls
        round_y = sz if obj.get("art_kind") == "wheel" else sy
        for v in obj.data.vertices:
            w = world @ v.co - location
            v.co = mathutils.Vector((w.x * sx, w.y * round_y, w.z * sz))
        obj.matrix_world = mathutils.Matrix.Translation(new_location)
        if "art_stride" in obj:
            # a stride is ground covered per step, which grows with the legs
            obj["art_stride"] = obj["art_stride"] * sz
        if "art_radius" in obj:
            # a wheel's radius is vertical, and grows with the model's height
            obj["art_radius"] = obj["art_radius"] * sz
    print(f"scaled to its collision volume by ({sx:.2f}, {sy:.2f}, {sz:.2f})")


def bounds_of(collider):
    """The (width, length, height) a def's collider gives its art: a box's own, and for a capsule the square the
    game gives its footprint (unit_defs' footprint_half_extents) by its height."""
    if collider["shape"] == "box":
        return (collider["width"], collider["length"], collider["height"])
    return (collider["radius"] * 2, collider["radius"] * 2, collider["height"])


def fit_problems(objects, def_entry, envelope):
    """How the finished model, as it is exported, misses its def's collider (`bounds_of`), standing centred on its
    origin, where its generator's `envelope` ({"width": ..., "length": ..., "height": ...}, any of them) does not
    let it reach further. Nothing may reach past its top, or
    below the ground unless the def floats (its origin is then the water's surface). Across, a unit is held to its
    capsule whole, a walking leg at either end of its stride included; a building's box is its footprint on the grid,
    which what stands still has to stay on, while its turrets, dishes and hatches swing out over its neighbours as
    BAR's do."""
    collider = def_entry["collider"]
    width, length, height = bounds_of(collider)
    bounds = [envelope.get("width", width), envelope.get("length", length), envelope.get("height", height)]
    lo, hi = world_bounds(objects, swinging=True)
    footing = objects if collider["shape"] == "capsule" else [o for o in objects if o.get("art_group", "base") == "base"]
    side_lo, side_hi = world_bounds(footing, swinging=True)
    problems = []
    for axis, name in ((0, "width"), (1, "length")):
        reach = max(abs(side_lo[axis]), abs(side_hi[axis]))
        if reach > bounds[axis] / 2 + FIT_TOLERANCE:
            problems.append(f"{name} {reach * 2:.3f} over {bounds[axis]:.3f}")
    if hi[2] > bounds[2] + FIT_TOLERANCE:
        problems.append(f"height {hi[2]:.3f} over {bounds[2]:.3f}")
    ground = world_bounds(objects)[0][2]
    if ground < -FIT_TOLERANCE and not def_entry["floats"]:
        problems.append(f"reaches {-ground:.3f} below the ground")
    return problems


def def_params(def_entry):
    """What a generator that declares a DEF gets from it: its collider (studs) and colour (0-1 RGBA)."""
    if def_entry is None:
        return {}
    r, g, b = def_entry["color"]
    return {"collider": def_entry["collider"], "color": (r / 255.0, g / 255.0, b / 255.0, 1.0)}


def def_of(module, defs):
    """The game's numbers for the def generator `module` declares (DEF), or None if it declares none."""
    def_name = getattr(module, "DEF", None)
    if def_name is None:
        return None
    if def_name not in defs:
        raise SystemExit(f"{module.__name__} declares DEF = {def_name!r}, which is not a def")
    return defs[def_name]


def mount_problems(mounts, groups, parts):
    """How the model's turrets disagree with the MOUNTS its generator declares (turret_mounts.py): each turret piece
    has to have a mount for its weapon, pivoting where the piece does and with its muzzle at the tip of its barrel."""
    turrets = {g["fields"]["weapon"]: name for name, g in groups.items() if g["fields"].get("kind") == "turret"}
    problems = []
    for weapon in sorted(set(turrets) | set(mounts)):
        if weapon not in mounts:
            problems.append(f"turret {turrets[weapon]} fires weapon {weapon}, which has no MOUNTS")
            continue
        if weapon not in turrets:
            problems.append(f"MOUNTS has weapon {weapon}, which no turret piece fires")
            continue
        art = {"pivot": groups[turrets[weapon]]["fields"]["pivot"], "muzzle": muzzle_of(turrets[weapon], parts)}
        for key, point in art.items():
            off = max(abs(a - b) for a, b in zip(point, mounts[weapon][key]))
            if off > turret_mounts.TOLERANCE:
                at = ", ".join(art_format.lua_number(c) for c in point)
                problems.append(f"weapon {weapon}'s {key} is at ({at}) in its art, {off:.3f} from its MOUNTS")
    return problems


def budget_problems(module, triangles, parts):
    """How the model overspends its category (or the TRIANGLES its generator declares instead)."""
    category = manifest.CATEGORIES[module.CATEGORY]
    allowed = getattr(module, "TRIANGLES", category["triangles"])
    problems = []
    if triangles > allowed:
        problems.append(f"{triangles} triangles, over the {allowed} it may spend")
    if category["parts"] is not None and parts > category["parts"]:
        problems.append(f"{parts} MeshParts, over the {category['parts']} a {module.CATEGORY} may have")
    return problems


def build(name, params, defs, out_dir, render, uploads):
    """Builds generator `name`; returns (its built.json entry, what is wrong with it)."""
    clear_scene()
    module = importlib.import_module(f"generators.{name}")
    category = manifest.CATEGORIES[module.CATEGORY]
    def_entry = def_of(module, defs)

    objects = module.generate({**def_params(def_entry), **params})
    if not objects:
        raise RuntimeError(f"generators.{name}.generate() returned nothing")
    # every location a generator set is in each object's matrix_world before the build reads it
    bpy.context.view_layer.update()
    collider = def_entry["collider"] if def_entry is not None else None
    if collider is not None and collider["shape"] == "capsule":
        fill_volume(objects, bar_volume(collider))
        bpy.context.view_layer.update()
    if category["centred"]:
        common.centre_footprint(objects)
        bpy.context.view_layer.update()
    problems = []
    if collider is not None and category["fits"]:
        problems += fit_problems(objects, def_entry, getattr(module, "ENVELOPE", {}))

    groups, parts = art_parts(objects)
    problems += mount_problems(getattr(module, "MOUNTS", {}), groups, parts)
    tris = triangle_count(objects)
    problems += budget_problems(module, tris, len(parts))
    print(f"{name}: {tris} triangles, {len(parts)} parts")

    output = Path(out_dir) if out_dir is not None else manifest.OUTPUT_DIRS[category["output"]]
    module_path = output / f"{name}.luau"
    text = export_art(groups, parts, module_path, name, uploads["assets"])
    pending = [part for part in parts if part["hash"] not in uploads["assets"]]
    glb = manifest.glb_path(name)
    if pending:
        export_upload_glb(pending, glb)
    elif glb.is_file():
        glb.unlink()
    if render:
        render_preview(objects, manifest.BUILD_DIR / f"{name}.png")

    entry = {
        "module": module_path.relative_to(manifest.REPO_ROOT).as_posix() if out_dir is None else "",
        "digest": manifest.module_digest(text),
        "hashes": [part["hash"] for part in parts],
        "blender": bpy.app.version_string,
        "inputs": manifest.fingerprint(name, def_entry),
        "pending": [part["hash"] for part in pending],
    }
    return entry, problems


def declared_def(name):
    """The DEF generator `name` declares, read without running it."""
    return getattr(importlib.import_module(f"generators.{name}"), "DEF", None)


def stale(names, built, defs, uploads):
    """Of `names`, the generators whose art module is out of date: never built, built from other inputs or by
    another Blender, or holding meshes uploaded since."""
    found = []
    for name in names:
        entry = built.get(name)
        def_name = declared_def(name)
        if (
            entry is None
            or entry["inputs"] != manifest.fingerprint(name, defs.get(def_name) if def_name is not None else None)
            or entry["blender"] != bpy.app.version_string
            or any(h in uploads["assets"] for h in entry["pending"])
        ):
            found.append(name)
    return found


def main():
    args = parse_args()
    names = manifest.generator_names()
    if args.list:
        print("\n".join(names))
        return
    if not bpy.app.version_string.startswith(manifest.BLENDER_VERSION + "."):
        raise SystemExit(
            f"this is Blender {bpy.app.version_string}; the pipeline builds with Blender {manifest.BLENDER_VERSION} "
            "(a mesh's hash depends on how Blender triangulates it)"
        )
    data = game_data.load(args.game_root) if args.game_root else game_data.load()
    defs = data["defs"]
    built = manifest.load_built()
    uploads = manifest.load_uploads()
    if args.all:
        chosen = names
    elif args.stale:
        chosen = stale(names, built, defs, uploads)
    else:
        chosen = args.generators
    if not chosen:
        raise SystemExit("nothing to build: name generators, or pass --all or --stale (--list lists them)")
    unknown = [n for n in chosen if n not in names]
    if unknown:
        raise SystemExit(f"no such generator: {', '.join(unknown)}")

    params = json.loads(args.params)
    failed = {}
    for name in chosen:
        print(f"== {name}")
        entry, problems = build(name, params, defs, args.out_dir, not args.no_render, uploads)
        if problems:
            failed[name] = problems
            print(f"PROBLEM {name}: {'; '.join(problems)}")
        if args.out_dir is None:
            built[name] = entry
            manifest.save_built(built)
    if args.out_dir is None:
        turret_mounts.write({name: manifest.declarations(name) for name in names})
    waiting = sorted(n for n in chosen if args.out_dir is None and built[n]["pending"])
    print(f"built {len(chosen)}")
    if waiting:
        print(f"waiting for an upload (roblox/upload_art.py): {', '.join(waiting)}")
    if failed:
        print(f"past their collider, their budget or their mounts: {', '.join(sorted(failed))}")
        sys.exit(1)


if __name__ == "__main__":
    main()
