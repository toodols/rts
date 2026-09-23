"""Headless Blender entry point for the procedural model pipeline.

Run via Blender itself, not plain python — bpy only exists inside Blender:

    blender --background --python tools/model_pipeline/build.py -- \\
        --generator building_basic --params '{"width":16}' --out build/building_basic.glb

Everything after the lone `--` is this script's own argv; Blender strips its own flags before it.
"""

import argparse
import hashlib
import importlib
import json
import math
import re
import sys
from pathlib import Path

import bmesh
import bpy
import mathutils

PIPELINE_ROOT = Path(__file__).resolve().parent
GENERATORS_DIR = PIPELINE_ROOT / "generators"
# Where the client finds each model's data, synced by Rojo into ReplicatedStorage.Shared.art.
ART_DIR = PIPELINE_ROOT.parent.parent / "src" / "shared" / "art"
# Which meshes are already on Roblox, by content hash (see roblox/upload_art.py). A part whose hash is in it is
# written as its asset id instead of its vertices.
UPLOADS_PATH = PIPELINE_ROOT / "roblox" / "uploads.json"
# The game is meant to carry thousands of units, so a model is a handful of strong low-poly shapes.
MAX_TRIANGLES_WARNING = 100


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--generator", help="module name under generators/, e.g. building_basic")
    parser.add_argument("--params", default="{}", help="JSON object passed to generate(params)")
    parser.add_argument("--out", default=None, help="output .glb path (default: build/<generator>.glb)")
    parser.add_argument(
        "--luau-out",
        default=None,
        help="also write the model's art data module, which the client builds meshes from at runtime "
        "(default: src/shared/art/<generator>.luau); pass --no-luau to skip it",
    )
    parser.add_argument("--no-luau", action="store_true", help="skip writing the art data module")
    parser.add_argument(
        "--render-out",
        default=None,
        help="also render a quick three-quarter view PNG for visual review "
        "(default: build/<generator>.png); pass --no-render to skip it",
    )
    parser.add_argument("--no-render", action="store_true", help="skip the preview render")
    parser.add_argument("--list", action="store_true", help="list available generators and exit")
    return parser.parse_args(argv)


def list_generators():
    for path in sorted(GENERATORS_DIR.glob("*.py")):
        if path.stem in ("__init__", "common"):
            continue
        print(path.stem)


def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()
    for mesh in list(bpy.data.meshes):
        if mesh.users == 0:
            bpy.data.meshes.remove(mesh)


def triangle_count(objects):
    total = 0
    for obj in objects:
        mesh = obj.data
        total += sum(len(p.vertices) - 2 for p in mesh.polygons)
    return total


# Edges sharper than this are split before export, so each side keeps its own vertex normal: Roblox computes
# an EditableMesh's normals by averaging across shared vertices, which would round a box's corners off.
SHARP_EDGE_DEGREES = 40.0


def material_of(obj):
    """(name, rgba color, glows) for an object's first material. An emissive material (apply_material's
    `emission`) glows, which becomes Neon in Roblox: the only way a part there actually lights up."""
    color = (1.0, 1.0, 1.0, 1.0)
    glows = False
    name = ""
    if obj.data.materials and obj.data.materials[0] is not None:
        mat = obj.data.materials[0]
        name = mat.name
        if mat.use_nodes:
            bsdf = mat.node_tree.nodes.get("Principled BSDF")
            if bsdf is not None:
                color = tuple(bsdf.inputs["Base Color"].default_value)
                if "Emission Strength" in bsdf.inputs:
                    glows = bsdf.inputs["Emission Strength"].default_value > 0.0
    return name, color, glows


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
    return (location.x, location.z, -location.y)


def collect_groups(objects):
    """The model's rigid pieces, by the `art_group` a generator set on each object (common.art_group): "base"
    for anything that set none. A piece's pivot is the location of its object marked `art_pivot`, or the model's
    origin; the rest of what the generator set (kind, weapon, axis, speed, swing, phase, stride) describes how it
    moves."""
    groups = {}
    for obj in objects:
        name = obj.get("art_group", "base")
        group = groups.setdefault(name, {"pivot": (0.0, 0.0, 0.0), "objects": [], "meta": {}})
        group["objects"].append(obj)
        if obj.get("art_pivot"):
            group["pivot"] = to_roblox(obj.location)
        for key in ("kind", "weapon", "speed", "swing", "phase", "stride", "radius", "open"):
            if f"art_{key}" in obj:
                group["meta"][key] = obj[f"art_{key}"]
        if "art_axis" in obj:
            x, y, z = obj["art_axis"]
            group["meta"]["axis"] = (x, z, -y)
    return groups


def lua_number(value):
    text = f"{value:.4f}".rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def load_uploads():
    if UPLOADS_PATH.is_file():
        return json.loads(UPLOADS_PATH.read_text(encoding="utf-8"))
    return {"meshes": {}, "models": {}}


def art_parts(objects):
    """(groups, parts): the model's rigid pieces, and one entry per mesh of them, each with its vertices centred
    on its own bounds, its size, its offset from its piece's pivot, and a hash of its geometry that names it on
    Roblox once it is uploaded."""
    groups = collect_groups(objects)
    parts = []
    for group_name, group in groups.items():
        by_material = {}
        for obj in group["objects"]:
            mat_name, color, glows = material_of(obj)
            entry = by_material.setdefault(mat_name, {"color": color, "glows": glows, "verts": [], "tris": []})
            verts, tris = world_triangles(obj)
            base = len(entry["verts"])
            entry["verts"].extend(verts)
            entry["tris"].extend((a + base, b + base, c + base) for a, b, c in tris)

        px, py, pz = group["pivot"]
        for mat_name, entry in by_material.items():
            verts = entry["verts"]
            lo = [min(v[i] for v in verts) for i in range(3)]
            hi = [max(v[i] for v in verts) for i in range(3)]
            centre = [(lo[i] + hi[i]) / 2 for i in range(3)]
            packed_verts = "|".join(",".join(lua_number(v[i] - centre[i]) for i in range(3)) for v in verts)
            # in a canonical order, each rotated to start at its lowest vertex (which keeps its winding): the order
            # Blender hands faces back in can vary between runs, and should not change the hash
            tris = sorted(min((t, t[1:] + t[:1], t[2:] + t[:2])) for t in entry["tris"])
            entry["tris"] = tris
            packed_tris = "|".join(f"{a},{b},{c}" for a, b, c in tris)
            digest = hashlib.sha1(f"{packed_verts}#{packed_tris}".encode("utf-8")).hexdigest()[:16]
            parts.append({
                "group": group_name,
                "material": mat_name,
                "color": entry["color"],
                "glows": entry["glows"],
                "offset": (centre[0] - px, centre[1] - py, centre[2] - pz),
                "size": tuple(hi[i] - lo[i] for i in range(3)),
                "centred": [tuple(v[i] - centre[i] for i in range(3)) for v in verts],
                "tris": entry["tris"],
                "packed_verts": packed_verts,
                "packed_tris": packed_tris,
                "hash": digest,
            })
    return groups, parts


def muzzle_of(group_name, parts):
    """Where a turret's shots leave it, relative to its pivot and at rest (Roblox axes, facing +Z): the point of
    its meshes that reaches furthest forward, which is the tip of its barrel, launcher or glowing muzzle. The server
    fires its weapon from there, turned with the turret's aim (server/combat.luau's weapon_origin)."""
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


def export_art(objects, out_path, model_name):
    """The model as a Luau data module the client dresses its entities from (src/client/art.luau).

    Each rigid piece (see collect_groups) becomes one MeshPart per material: everything that shares a color and
    moves together is one mesh. Each part's vertices are centred on their own bounds, and `offset` places that
    centre relative to its piece's pivot, which is relative to the model's origin: the middle of its footprint, on
    the ground, facing +Z. A mesh that has been uploaded (roblox/uploads.json) is written as its asset id; one
    that has not is written as its vertices and triangles, packed as "x,y,z|x,y,z|..." strings, which the client
    builds with EditableMesh. Returns the parts, for export_upload_glb."""
    groups, parts = art_parts(objects)
    uploaded = load_uploads()["meshes"]
    lines = [
        f"-- Generated by tools/model_pipeline from generators/{model_name}.py. Do not edit: rebuild it instead.",
        "return {",
        "\tgroups = {",
    ]
    for name, group in groups.items():
        fields = [f'pivot = {{ {", ".join(lua_number(c) for c in group["pivot"])} }}']
        meta = group["meta"]
        if "kind" in meta:
            fields.append(f'kind = "{meta["kind"]}"')
        if "weapon" in meta:
            fields.append(f'weapon = {int(meta["weapon"])}')
        if "axis" in meta:
            fields.append(f'axis = {{ {", ".join(lua_number(c) for c in meta["axis"])} }}')
        for key in ("speed", "swing", "phase", "stride", "radius", "open"):
            if key in meta:
                fields.append(f"{key} = {lua_number(meta[key])}")
        muzzle = muzzle_of(name, parts) if meta.get("kind") == "turret" else None
        if muzzle is not None:
            fields.append(f'muzzle = {{ {", ".join(lua_number(c) for c in muzzle)} }}')
        lines.append(f'\t\t{name} = {{ {", ".join(fields)} }},')
    lines.append("\t},")
    lines.append("\tparts = {")

    missing = 0
    for part in parts:
        r, g, b, _ = part["color"]
        fields = [
            f'group = "{part["group"]}"',
            f"color = {{ {lua_number(r)}, {lua_number(g)}, {lua_number(b)} }}",
            f'offset = {{ {", ".join(lua_number(c) for c in part["offset"])} }}',
            f'size = {{ {", ".join(lua_number(c) for c in part["size"])} }}',
            f'hash = "{part["hash"]}"',
        ]
        if part["glows"]:
            fields.append("neon = true")
        # the family's accent is what takes the team's colour, as a "Team" part does on any other model
        if "accent" in part["material"]:
            fields.append("team = true")
        mesh = uploaded.get(part["hash"])
        if mesh is not None:
            fields.append(f'mesh = "{mesh}"')
            lines.append(f"\t\t{{ {', '.join(fields)} }},")
        else:
            missing += 1
            lines.append(f"\t\t{{ {', '.join(fields)},")
            lines.append(f'\t\t\tvertices = "{part["packed_verts"]}",')
            lines.append(f'\t\t\ttriangles = "{part["packed_tris"]}" }},')
    lines.append("\t},")
    lines.append("}")
    lines.append("")

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"wrote {out_path} ({len(parts)} parts, {missing} not uploaded)")
    return parts


def export_upload_glb(parts, out_path):
    """Every mesh of the art as one node of a .glb, named by its hash and centred as the art has it, for
    roblox/upload_art.py to upload as one Model. Uploading makes one mesh asset per node, which is what the art
    module then refers to."""
    made = []
    for part in parts:
        obj = common_new_object(part["hash"])
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


def common_new_object(name):
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


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
    for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE"):
        try:
            scene.render.engine = engine
            break
        except TypeError:
            continue
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


# BAR measures in elmos, 11 to a stud (src/shared/unit_defs/conversions.luau).
ELMOS_PER_STUD = 11.0
UNIT_DEFS_DIR = PIPELINE_ROOT.parent.parent / "src" / "shared" / "unit_defs"
# How much more one axis of a unit may be stretched than the one stretched least, so that filling its collision
# volume widens a long tank or heightens a flat one without turning it into a cube.
MAX_STRETCH = 1.35


def unit_volume(def_name):
    """A unit's BAR collision volume in studs, (width, length, height) in Blender's (x, y, z), from the
    `capsule(width, height, length)` its def is given in elmos; None for anything that is not a unit."""
    for path in UNIT_DEFS_DIR.glob("*.luau"):
        source = path.read_text(encoding="utf-8")
        block = re.search(rf"\n\t{re.escape(def_name)} = \{{\n(.*?)\n\t\}},", source, re.S)
        if block is None:
            continue
        capsule = re.search(r"collider = capsule\(([\d.]+), ([\d.]+), ([\d.]+)\)", block.group(1))
        if capsule is None:
            return None
        width, height, length = (float(v) / ELMOS_PER_STUD for v in capsule.groups())
        return (width, length, height)
    return None


def fill_volume(objects, volume):
    """Scales a unit up to fill its BAR collision volume, which is the size BAR draws it at: a model designed to fit
    inside the collider's cylinder is a rectangle inscribed in its circle, well short of the volume's own width and
    length. Each axis is stretched as far as it takes to fill, but never shrunk and never more than MAX_STRETCH times
    the axis stretched least, so the design keeps its proportions. The model is scaled about its origin (the middle
    of its footprint, on the ground) and every rotation is baked into its mesh, so each piece keeps its pivot."""
    lo = [math.inf] * 3
    hi = [-math.inf] * 3
    for obj in objects:
        for v in obj.data.vertices:
            w = obj.matrix_world @ v.co
            for i in range(3):
                lo[i] = min(lo[i], w[i])
                hi[i] = max(hi[i], w[i])
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


def build(generator_name, params, out_path, luau_out_path=None, render_out_path=None):
    clear_scene()

    sys.path.insert(0, str(PIPELINE_ROOT))
    module = importlib.import_module(f"generators.{generator_name}")
    importlib.reload(module)

    objects = module.generate(params)
    if not objects:
        raise RuntimeError(f"generators.{generator_name}.generate() returned nothing")

    tris = triangle_count(objects)
    if tris > MAX_TRIANGLES_WARNING:
        print(f"warning: {tris} triangles, above the {MAX_TRIANGLES_WARNING} a model may have")

    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]

    # Recenter on X/Y (Blender) so the model's footprint straddles its own origin, the way the game centres an
    # entity's model on its collider. The footprint is the first object a generator returns (its footing):
    # centring on everything would pull a model off its collider by half of whatever reaches out past it,
    # like a tower's barrel.
    corners = [objects[0].matrix_world @ mathutils.Vector(corner) for corner in objects[0].bound_box]
    min_x = min(c.x for c in corners)
    max_x = max(c.x for c in corners)
    min_y = min(c.y for c in corners)
    max_y = max(c.y for c in corners)
    center_x = (min_x + max_x) / 2
    center_y = (min_y + max_y) / 2
    if abs(center_x) > 1e-6 or abs(center_y) > 1e-6:
        for obj in objects:
            obj.location.x -= center_x
            obj.location.y -= center_y

    volume = unit_volume(generator_name)
    if volume is not None:
        fill_volume(objects, volume)
        tris = triangle_count(objects)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.export_scene.gltf(
        filepath=str(out_path),
        export_format="GLB",
        use_selection=True,
        export_apply=True,
        export_yup=True,  # glTF is Y-up; Roblox importer expects this
    )
    print(f"wrote {out_path} ({tris} triangles)")

    if luau_out_path is not None:
        parts = export_art(objects, luau_out_path, generator_name)
        export_upload_glb(parts, PIPELINE_ROOT / "build" / f"{generator_name}_art.glb")

    if render_out_path is not None:
        render_preview(objects, render_out_path)


def main():
    args = parse_args()
    if args.list:
        list_generators()
        return
    if not args.generator:
        raise SystemExit("--generator is required (or pass --list)")

    params = json.loads(args.params)
    out_path = Path(args.out) if args.out else PIPELINE_ROOT / "build" / f"{args.generator}.glb"
    if args.no_luau:
        luau_out_path = None
    else:
        luau_out_path = Path(args.luau_out) if args.luau_out else ART_DIR / f"{args.generator}.luau"
    if args.no_render:
        render_out_path = None
    else:
        render_out_path = Path(args.render_out) if args.render_out else PIPELINE_ROOT / "build" / f"{args.generator}.png"
    build(args.generator, params, out_path, luau_out_path, render_out_path)


if __name__ == "__main__":
    main()
