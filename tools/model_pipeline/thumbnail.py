"""Renders the game's thumbnail: the game's own unit models, built by their generators, staged as a battle.

Run via Blender itself (bpy only exists inside Blender):

    blender --background --python tools/model_pipeline/thumbnail.py

By default it writes the game icon, marketing/icon.png (512x512, from a 1024 Cycles render kept as icon_large.png);
`--shot poster` writes marketing/thumbnail.png (1920x1080) instead. `--out`, `--width`, `--height` override.
`--probe [defs...]` prints each cast member (or each named def)'s size and exits, for placing them. `--samples` trades speed for noise.
"""

import argparse
import importlib
import math
import random
import sys
from pathlib import Path

import bpy
import mathutils

PIPELINE_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PIPELINE_ROOT))

import build as pipeline  # noqa: E402  (needs the path above)

TITLE_TOP = "BLOCKY"
TITLE_BOTTOM = "ANNIHILATION"
FONT = Path("C:/Windows/Fonts/impact.ttf")

# src/shared/appearance.luau's TEAM_COLORS, and its team_tint: a def's accent leans 45% toward its team's colour
BLUE = (86 / 255, 148 / 255, 224 / 255)
RED = (214 / 255, 92 / 255, 84 / 255)
TEAM_TINT = 0.45
# the marketing art leans harder than the game, so the sides read apart at thumbnail size
MARKETING_TINT = 0.75
# the bolts' colours, purer than the team colours: a glow's hue is all there is to tell the two sides' fire apart
BLUE_BOLT = (0.15, 0.5, 1.0)
RED_BOLT = (1.0, 0.16, 0.08)

random.seed(7)


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    parser = argparse.ArgumentParser()
    parser.add_argument("--shot", choices=("icon", "poster"), default="icon")
    parser.add_argument("--out", default=None)
    parser.add_argument("--width", type=int, default=None)
    parser.add_argument("--height", type=int, default=None)
    parser.add_argument("--samples", type=int, default=None)
    parser.add_argument("--probe", nargs="*", default=None)
    args = parser.parse_args(argv)
    marketing = PIPELINE_ROOT.parent.parent / "marketing"
    if args.shot == "icon":
        # Roblox's game icon is 512x512: render it at 1024, then write a 512 copy beside it
        args.out = args.out or str(marketing / "icon_large.png")
        args.width = args.height = args.width or 1024
        args.samples = args.samples or 256
        args.small = 512 if "_large" in args.out else None
    else:
        args.out = args.out or str(marketing / "thumbnail.png")
        args.width = args.width or 1920
        args.height = args.height or 1080
        args.samples = args.samples or 128
        args.small = None
    return args


# --- materials ---------------------------------------------------------------------------------------------------


def flat_material(name, color, emission=0.0, roughness=0.6, metallic=0.0):
    mat = bpy.data.materials.get(name)
    if mat is not None:
        return mat
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color[:3], 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    if emission > 0:
        bsdf.inputs["Emission Color"].default_value = (*color[:3], 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission
    return mat


_team_materials = {}
# each team's spawned units, as (root, objects), for the lights that pick out one side
members = {BLUE: [], RED: []}


def team_material(mat, team):
    key = (mat.name, team)
    if key not in _team_materials:
        copy = mat.copy()
        copy.name = f"{mat.name}_{'blue' if team is BLUE else 'red'}"
        bsdf = copy.node_tree.nodes.get("Principled BSDF")
        base = bsdf.inputs["Base Color"].default_value
        tinted = tuple(base[i] + (team[i] - base[i]) * MARKETING_TINT for i in range(3))
        bsdf.inputs["Base Color"].default_value = (*tinted, 1.0)
        if bsdf.inputs["Emission Strength"].default_value > 0:
            bsdf.inputs["Emission Color"].default_value = (*tinted, 1.0)
        _team_materials[key] = copy
    return _team_materials[key]


# --- units -------------------------------------------------------------------------------------------------------


_game_defs = None


def game_defs():
    """The game's defs, as build.py reads them (tools/game_data.py), read once."""
    global _game_defs
    if _game_defs is None:
        _game_defs = pipeline.game_data.load()["defs"]
    return _game_defs


def generate(def_name):
    """The def's objects exactly as build.py makes them (its `build`): given its def's collider and colour, filled to
    its collider, and with its footprint centred on the origin if its category centres it."""
    module = importlib.import_module(f"generators.{def_name}")
    def_entry = pipeline.def_of(module, game_defs())
    objects = module.generate(pipeline.def_params(def_entry))
    bpy.context.view_layer.update()
    collider = def_entry["collider"] if def_entry is not None else None
    if collider is not None and collider["shape"] == "capsule":
        pipeline.fill_volume(objects, pipeline.bar_volume(collider))
        bpy.context.view_layer.update()
    if pipeline.manifest.CATEGORIES[module.CATEGORY]["centred"]:
        pipeline.common.centre_footprint(objects)
        bpy.context.view_layer.update()
    return objects


def spawn(def_name, team, location, facing, scale=1.0, tilt=(0.0, 0.0)):
    """One unit of `team` at `location`, turned so its front (Blender -Y) points along world angle `facing`
    (degrees, 0 = toward the camera)."""
    objects = generate(def_name)
    for obj in objects:
        for slot in obj.material_slots:
            if team is not None and slot.material is not None and "accent" in slot.material.name:
                slot.material = team_material(slot.material, team)
    root = bpy.data.objects.new(f"{def_name}_root", None)
    bpy.context.collection.objects.link(root)
    for obj in objects:
        if obj.parent is None:
            obj.parent = root
    root.location = location
    root.rotation_euler = (math.radians(tilt[0]), math.radians(tilt[1]), math.radians(facing))
    root.scale = (scale, scale, scale)
    if team is not None:
        members[team].append((root, objects))
    return root, objects


def probe(names):
    for name in names:
        pipeline.clear_scene()
        objects = generate(name)
        corners = [o.matrix_world @ mathutils.Vector(c) for o in objects for c in o.bound_box]
        size = [max(c[i] for c in corners) - min(c[i] for c in corners) for i in range(3)]
        print(f"PROBE {name}: {size[0]:.1f} x {size[1]:.1f} x {size[2]:.1f}")


# --- set ---------------------------------------------------------------------------------------------------------


def low_poly(name, verts, faces, mat):
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(verts, [], faces)
    mesh.update()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(mat)
    return obj


def terrain(scorches=((0.5, 4, 5.5),)):
    """A faceted field: flat where the armies stand, rising into hills behind them. `scorches` are (x, y, radius)
    burnt patches, where shells have landed."""
    size, cells = 600.0, 150
    step = size / cells
    verts = []
    for j in range(cells + 1):
        for i in range(cells + 1):
            x = -size / 2 + i * step + random.uniform(-0.3, 0.3) * step
            y = -size / 4 + j * step + random.uniform(-0.3, 0.3) * step
            far = max(0.0, y - 45.0)
            h = random.uniform(-0.4, 0.4) + (far / 120.0) ** 1.4 * (8 + 6 * math.sin(x * 0.02) + 7 * math.cos(x * 0.011 + 1))
            verts.append((x, y, h))
    faces = []
    for j in range(cells):
        for i in range(cells):
            a = j * (cells + 1) + i
            b, c, d = a + 1, a + cells + 2, a + cells + 1
            if (i + j) % 2:
                faces += [(a, b, c), (a, c, d)]
            else:
                faces += [(a, b, d), (b, c, d)]
    ground = low_poly("terrain", verts, faces, flat_material("terrain_grass", (0.22, 0.34, 0.14), roughness=0.9))
    # a second, earthier colour on some facets breaks it up the way the game's terrain does
    dirt = flat_material("terrain_dirt", (0.17, 0.26, 0.11), roughness=0.95)
    scorched = flat_material("terrain_scorched", (0.07, 0.06, 0.05), roughness=1.0)
    ground.data.materials.append(dirt)
    ground.data.materials.append(scorched)
    for poly in ground.data.polygons:
        c = poly.center
        if any(math.hypot(c.x - x, c.y - y) < r * random.uniform(0.7, 1.25) for x, y, r in scorches):
            poly.material_index = 2
        elif random.random() < 0.35:
            poly.material_index = 1
    return ground


def blast(center, radius, glow=1.0):
    """A low-poly fireball: glowing icospheres, a smoke cap and flying chunks. `glow` scales the light it throws."""
    hot = flat_material("blast_hot", (1.0, 0.85, 0.35), emission=6.0)
    warm = flat_material("blast_warm", (1.0, 0.42, 0.08), emission=3.0)
    smoke = flat_material("blast_smoke", (0.10, 0.09, 0.09), roughness=1.0)
    debris = flat_material("blast_debris", (0.16, 0.15, 0.15), roughness=0.7, metallic=0.4)
    cx, cy, cz = center

    def ico(mat, loc, r, subdiv=1):
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=subdiv, radius=r, location=loc)
        obj = bpy.context.active_object
        obj.rotation_euler = [random.uniform(0, 6.28) for _ in range(3)]
        obj.data.materials.append(mat)
        return obj

    for _ in range(9):
        d = mathutils.Vector((random.uniform(-1, 1), random.uniform(-0.6, 0.6), random.uniform(-0.2, 1))).normalized()
        ico(warm, (cx + d.x * radius * 0.7, cy + d.y * radius * 0.7, cz + d.z * radius * 0.6), radius * random.uniform(0.45, 0.7))
    for _ in range(5):
        d = mathutils.Vector((random.uniform(-1, 1), random.uniform(-1, 1), random.uniform(-0.3, 0.8))).normalized()
        ico(hot, (cx + d.x * radius * 0.35, cy + d.y * radius * 0.35, cz + d.z * radius * 0.35), radius * random.uniform(0.35, 0.55))
    for _ in range(5):
        d = mathutils.Vector((random.uniform(-1, 1), random.uniform(0.2, 1.0), random.uniform(0.9, 1.4)))
        ico(smoke, (cx + d.x * radius, cy + d.y * radius, cz + d.z * radius * 1.3), radius * random.uniform(0.5, 0.8))
    for _ in range(26):
        d = mathutils.Vector((random.uniform(-1, 1), random.uniform(-1, 0.4), random.uniform(0.1, 1))).normalized()
        dist = radius * random.uniform(1.2, 2.6)
        s = random.uniform(0.25, 0.8)
        bpy.ops.mesh.primitive_cube_add(size=s, location=(cx + d.x * dist, cy + d.y * dist, cz + d.z * dist))
        obj = bpy.context.active_object
        obj.rotation_euler = [random.uniform(0, 6.28) for _ in range(3)]
        obj.data.materials.append(debris if random.random() < 0.6 else warm)

    light = bpy.data.lights.new("blast_light", type="POINT")
    light.color = (1.0, 0.55, 0.2)
    light.energy = 4000 * (radius / 3.0) ** 2 * glow
    light.shadow_soft_size = radius
    obj = bpy.data.objects.new("blast_light", light)
    obj.location = (cx, cy, cz + radius * 0.3)
    bpy.context.collection.objects.link(obj)


def bar(start, end, width, mat, name):
    """A long thin box from start to end."""
    a, b = mathutils.Vector(start), mathutils.Vector(end)
    bpy.ops.mesh.primitive_cube_add(size=1, location=(a + b) / 2)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (width, (b - a).length, width)
    obj.rotation_euler = (b - a).to_track_quat("Y", "Z").to_euler()
    obj.data.materials.append(mat)
    return obj


def beam(start, end, color, width=0.35, name="beam"):
    """A glowing bolt from start to end, like the game's laser bolts: a white-hot core in a shell of the side's
    colour, kept dim enough not to clip, so the colour survives instead of burning out to white."""
    core = tuple(0.8 + 0.2 * c for c in color)
    bar(start, end, width * 0.4, flat_material(f"beam_core_{color}", core, emission=4.0), name)
    shell = flat_material(f"beam_shell_{color}", color, emission=1.1)
    bsdf = shell.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Alpha"].default_value = 0.55
    return bar(start, end, width, shell, f"{name}_shell")


def nano_beam(start, end):
    """A constructor's green build stream, reaching into whatever it is building."""
    return bar(start, end, 0.12, flat_material("nano", (0.3, 1.0, 0.35), emission=5.0), "nano")


def smoke_column(base, height, lean=(1.0, 0.4)):
    """Black smoke rising off a wreck, thinning and greying as it climbs and leaning with the wind."""
    shades = [flat_material(f"smoke_{i}", (v, v, v * 0.97), roughness=1.0)
              for i, v in enumerate((0.04, 0.1, 0.2, 0.32))]
    flame = flat_material("wreck_flame", (1.0, 0.45, 0.1), emission=6.0)
    x, y, z = base
    steps = max(4, int(height / 1.1))
    for i in range(steps):
        t = i / (steps - 1)
        r = 0.35 + 1.5 * t * t
        loc = (x + lean[0] * t * height * 0.35 + random.uniform(-0.3, 0.3),
               y + lean[1] * t * height * 0.35 + random.uniform(-0.3, 0.3), z + t * height)
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=r * random.uniform(0.8, 1.1), location=loc)
        obj = bpy.context.active_object
        obj.rotation_euler = [random.uniform(0, 6.28) for _ in range(3)]
        obj.data.materials.append(shades[min(3, int(t * 4))])
    for _ in range(3):
        at = (x + random.uniform(-0.6, 0.6), y + random.uniform(-0.6, 0.6), z)
        bpy.ops.mesh.primitive_ico_sphere_add(subdivisions=1, radius=random.uniform(0.35, 0.6), location=at)
        bpy.context.active_object.data.materials.append(flame)


def wreck(def_name, location, facing, smoke=6.0):
    """A burnt-out unit: its own model, charred, knocked askew and half sunk, still smoking."""
    char = flat_material("wreck_char", (0.045, 0.04, 0.035), roughness=0.85, metallic=0.3)
    root, objects = spawn(def_name, None, location, facing, tilt=(random.uniform(-14, 14), random.uniform(-14, 14)))
    for obj in objects:
        for slot in obj.material_slots:
            slot.material = char
    root.location.z -= 0.35
    if smoke:
        smoke_column((location[0], location[1], location[2] + 1.2), smoke)
    return root


def team_rim(name, team, energy, rot):
    """A sun in the team's colour that lights only that team's units (Cycles light linking), so the two armies
    read apart at a glance by the edges of their hulls."""
    coll = bpy.data.collections.new(f"{name}_members")
    bpy.context.scene.collection.children.link(coll)
    for root, objects in members[team]:
        for obj in (root, *objects):
            coll.objects.link(obj)
    data = bpy.data.lights.new(name, type="SUN")
    data.energy = energy
    data.color = tuple(0.15 + 0.85 * c for c in team)
    data.angle = math.radians(3)
    obj = bpy.data.objects.new(name, data)
    obj.rotation_euler = tuple(math.radians(a) for a in rot)
    bpy.context.collection.objects.link(obj)
    obj.light_linking.receiver_collection = coll
    return obj


def sky():
    world = bpy.data.worlds.get("World") or bpy.data.worlds.new("World")
    bpy.context.scene.world = world
    world.use_nodes = True
    nodes, links = world.node_tree.nodes, world.node_tree.links
    nodes.clear()
    coords = nodes.new("ShaderNodeTexCoord")
    sep = nodes.new("ShaderNodeSeparateXYZ")
    ramp = nodes.new("ShaderNodeValToRGB")
    bg = nodes.new("ShaderNodeBackground")
    out = nodes.new("ShaderNodeOutputWorld")
    links.new(coords.outputs["Generated"], sep.inputs[0])
    links.new(sep.outputs["Z"], ramp.inputs["Fac"])
    # the camera sees a dusk gradient, but the scene is lit by a neutral sky, or the metal hulls all mirror orange
    path = nodes.new("ShaderNodeLightPath")
    mix = nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    # the Mix node carries float, vector and colour sockets under the same names; 6/7/2 are the colour ones
    mix.inputs[6].default_value = (0.42, 0.47, 0.55, 1)
    links.new(path.outputs["Is Camera Ray"], mix.inputs["Factor"])
    links.new(ramp.outputs["Color"], mix.inputs[7])
    links.new(mix.outputs[2], bg.inputs["Color"])
    links.new(bg.outputs["Background"], out.inputs["Surface"])
    els = ramp.color_ramp.elements
    els[0].position, els[0].color = 0.0, (1.0, 0.66, 0.34, 1)
    els[1].position, els[1].color = 0.34, (0.09, 0.16, 0.36, 1)
    mid = els.new(0.1)
    mid.color = (0.85, 0.40, 0.30, 1)
    bg.inputs["Strength"].default_value = 1.0


def sun():
    """A low evening sun to match the dusk sky: warm, raking across the field so every unit throws a long shadow."""
    data = bpy.data.lights.new("sun", type="SUN")
    data.energy = 4.2
    data.color = (1.0, 0.8, 0.6)
    data.angle = math.radians(2)
    obj = bpy.data.objects.new("sun", data)
    obj.rotation_euler = (math.radians(72), 0, math.radians(-125))
    bpy.context.collection.objects.link(obj)
    fill = bpy.data.lights.new("fill", type="SUN")
    fill.energy = 0.8
    fill.color = (0.55, 0.65, 1.0)
    obj = bpy.data.objects.new("fill", fill)
    obj.rotation_euler = (math.radians(55), 0, math.radians(60))
    bpy.context.collection.objects.link(obj)


POSTER_TITLE = ((TITLE_TOP, 0.105, 0.225), (TITLE_BOTTOM, 0.135, 0.12))


def title(camera, lines=POSTER_TITLE):
    """The name as chunky extruded letters, parented to the camera so it sits in frame whatever the shot: `lines`
    is (text, size, height in frame) for each line, at a unit in front of the camera."""
    font = bpy.data.fonts.load(str(FONT))
    face = flat_material("title_face", (1.0, 0.5, 0.04), emission=0.6, roughness=0.3)
    side = flat_material("title_side", (0.12, 0.05, 0.03), roughness=0.5)
    objs = []
    for text, size, y in lines:
        curve = bpy.data.curves.new(f"title_{text}", type="FONT")
        curve.body = text
        curve.font = font
        curve.size = size
        curve.align_x = "CENTER"
        curve.align_y = "CENTER"
        curve.extrude = size * 0.12
        curve.bevel_depth = size * 0.02
        curve.bevel_resolution = 0
        obj = bpy.data.objects.new(f"title_{text}", curve)
        bpy.context.collection.objects.link(obj)
        obj.data.materials.append(face)
        obj.data.materials.append(side)
        obj.parent = camera
        obj.location = (0.0, y, -1.0)
        obj.rotation_euler = (math.radians(-6), 0, 0)
        objs.append(obj)
    # the letters' faces bright and their extruded sides dark: as meshes, each polygon is painted by which way it faces
    for obj in objs:
        bpy.context.view_layer.objects.active = obj
        bpy.ops.object.select_all(action="DESELECT")
        obj.select_set(True)
        bpy.ops.object.convert(target="MESH")
        for poly in obj.data.polygons:
            poly.material_index = 0 if poly.normal.z > 0.9 else 1
    return objs


# --- shot --------------------------------------------------------------------------------------------------------


def army(team, kinds, xs, ys, facing, spacing=4.5, skip=()):
    """A jittered block of units filling x and y ranges, each turned roughly along `facing`: numbers, so a side reads
    as an army and not a squad. `skip` is (x, y, radius) spots left clear for the heroes."""
    y = ys[0]
    while y < ys[1]:
        x = xs[0] + random.uniform(0, spacing)
        while x < xs[1]:
            at = (x + random.uniform(-1.2, 1.2), y + random.uniform(-1.2, 1.2), 0)
            if not any(math.hypot(at[0] - sx, at[1] - sy) < sr for sx, sy, sr in skip):
                spawn(random.choice(kinds), team, at, facing + random.uniform(-12, 12))
            x += spacing * random.uniform(0.9, 1.3)
        y += spacing * random.uniform(0.9, 1.2)


def base(team, x0, y0, flip):
    """A corner of a team's base behind its army: a factory, mexes, power and a constructor raising a turret."""
    s = -1 if flip else 1
    spawn("vehicle_lab" if flip else "bot_lab", team, (x0, y0 + 10, 0), 180 + 20 * s)
    spawn("metal_extractor", team, (x0 + 13 * s, y0 + 2, 0), 0)
    spawn("metal_extractor", team, (x0 - 4 * s, y0 - 2, 0), 30)
    spawn("solar_collector", team, (x0 - 14 * s, y0 + 6, 0), 0)
    spawn("wind_turbine", team, (x0 + 20 * s, y0 + 12, 0), 0)
    spawn("wind_turbine", team, (x0 - 20 * s, y0 + 16, 0), 0)
    con = (x0 + 6 * s, y0 - 6, 0)
    spawn("construction_vehicle" if flip else "construction_bot", team, con, -90 * s)
    turret = (x0 + 11 * s, y0 - 8, 0)
    spawn("guard", team, turret, 90 * s)
    nano_beam((con[0], con[1], 2.4), (turret[0], turret[1], 3.0))


def stage():
    pipeline.clear_scene()
    for block in (bpy.data.materials, bpy.data.lights, bpy.data.cameras, bpy.data.curves):
        for item in list(block):
            block.remove(item)

    cam_data = bpy.data.cameras.new("camera")
    cam_data.lens = 27
    cam_data.clip_end = 2000
    camera = bpy.data.objects.new("camera", cam_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (0, -38, 6.0)
    target = mathutils.Vector((0, 6, 6.0))
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = camera

    sky()
    sun()
    # where shells have landed: the ground between the armies is burnt and littered with wrecks
    wrecks = ((-13, 14, "tiger", 30), (5, -3, "sumo", -110), (15, 17, "brute", 160), (-5, -2, "grunt", 70),
              (-22, 32, "tiger", -20), (24, 34, "sumo", 200))
    terrain(scorches=((0.5, 4, 5.0), *((x, y, 3.0) for x, y, _, _ in wrecks), (-3, 26, 4), (9, 34, 4)))
    haze(0.0015, 15)

    # the heroes, up front: the blue commander at the left, a red juggernaut wading in from the right
    spawn("commander", BLUE, (-7, -16, 0), 55)
    spawn("tiger", BLUE, (-15, -10, 0), 62)
    spawn("tiger", BLUE, (-20, -4, 0), 66)
    spawn("grunt", BLUE, (-11, -7, 0), 55)
    spawn("juggernaut", RED, (14, -4, 0), -42)
    spawn("sumo", RED, (6, 1, 0), -65)
    spawn("sumo", RED, (16, 3, 0), -60)
    spawn("brute", RED, (4, -9, 0), -70)

    # and the two armies behind them, back to their bases
    clear = ((-7, -16, 6), (14, -4, 7))
    army(BLUE, ("grunt", "grunt", "tiger", "tiger", "janus"), (-42, -7), (-12, 44), 70, skip=clear)
    army(RED, ("brute", "sumo", "sumo", "thor", "brute"), (7, 42), (-8, 46), -75, skip=clear)
    base(BLUE, -30, 44, False)
    base(RED, 30, 46, True)

    for name, x, y in (("tree", -52, 40), ("tree", -48, 50), ("tree", 50, 44), ("tree", 56, 36),
                       ("rock", -2, 16), ("shrub", 24, -16), ("shrub", -24, -14), ("tree", -4, 70), ("rock", 28, 10)):
        spawn(name, None, (x, y, 0), random.uniform(0, 360))
    for x, y, kind, facing in wrecks:
        wreck(kind, (x, y, 0), facing, smoke=random.uniform(5, 9))

    # a dogfight in the open sky left of the title, clear of every head: blue fighters out, red bombers coming in
    spawn("valiant", BLUE, (-11, -12, 12), 75, tilt=(0, -22))
    spawn("valiant", BLUE, (-20, 4, 17), 70, tilt=(0, -15))
    spawn("nighthawk", RED, (-4, -2, 14.5), -100, tilt=(0, 18))
    spawn("nighthawk", RED, (-26, 26, 24), -80, tilt=(0, 12))

    # the fight: one big hit in the middle and more going off down the line
    blast((0.5, 4, 1.6), 3.0)
    blast((-3, 26, 1.2), 1.8)
    blast((9, 34, 1.0), 1.6)
    beam((-5.4, -14.5, 3.6), (0, 3, 2), BLUE_BOLT, width=0.3, name="commander_bolt")
    beam((-13.5, -8.5, 1.4), (-1, 5, 1.2), BLUE_BOLT, width=0.2)
    beam((-18, 12, 1.4), (-4, 25, 1.2), BLUE_BOLT, width=0.2)
    beam((11.6, -5.6, 7.4), (-3, -1, 1.8), RED_BOLT, width=0.35)
    beam((4.5, 2, 1.5), (-4, 3, 1.5), RED_BOLT, width=0.2)
    beam((14, 22, 1.5), (-2, 26, 1.2), RED_BOLT, width=0.2)

    team_rim("blue_rim", BLUE, 3.0, (70, 0, 150))
    team_rim("red_rim", RED, 3.0, (70, 0, -150))
    title(camera)
    return camera


def haze(density, near_y):
    """Air between the camera and the far hills, so distance reads as depth: a volume box over the field from
    `near_y` back (Cycles only). Not a world volume, which would swallow the sun on its way in from infinity."""
    mat = bpy.data.materials.new("haze")
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.remove(nodes["Principled BSDF"])
    volume = nodes.new("ShaderNodeVolumePrincipled")
    volume.inputs["Color"].default_value = (0.95, 0.75, 0.62, 1)
    volume.inputs["Density"].default_value = density
    links.new(volume.outputs["Volume"], nodes["Material Output"].inputs["Volume"])
    depth, height = 400.0, 45.0
    bpy.ops.mesh.primitive_cube_add(size=1, location=(0, near_y + depth / 2, height / 2 - 2))
    box = bpy.context.active_object
    box.name = "haze"
    box.scale = (600, depth, height)
    box.data.materials.append(mat)


def icon_lights():
    """Harder than the poster's: a low warm key from the front right, on the commander, and little sky fill, so each
    block of a model has a lit face, a shadowed face and an edge; each side gets a rim in its own colour from behind
    (see team_rim)."""
    data = bpy.data.lights.new("key", type="SUN")
    data.energy = 3.0
    data.color = (1.0, 0.84, 0.66)
    data.angle = math.radians(2)
    obj = bpy.data.objects.new("key", data)
    obj.rotation_euler = tuple(math.radians(a) for a in (58, 0, 35))
    bpy.context.collection.objects.link(obj)
    mix = next(n for n in bpy.context.scene.world.node_tree.nodes if n.bl_idname == "ShaderNodeMix")
    mix.inputs[6].default_value = (0.16, 0.18, 0.24, 1)


# at the top, over the sky, so the fight below keeps the frame: both lines the same letter height, reading as one name
ICON_TITLE = ((TITLE_TOP, 0.21, 0.54), (TITLE_BOTTOM, 0.21, 0.36))


def icon_stage():
    """A square close-up for the game icon: the blue commander firing up at a red juggernaut looming over it."""
    pipeline.clear_scene()
    for block in (bpy.data.materials, bpy.data.lights, bpy.data.cameras, bpy.data.curves):
        for item in list(block):
            block.remove(item)

    cam_data = bpy.data.cameras.new("camera")
    cam_data.lens = 24
    cam_data.clip_end = 2000
    camera = bpy.data.objects.new("camera", cam_data)
    bpy.context.collection.objects.link(camera)
    camera.location = (-0.5, -19.5, 1.0)
    target = mathutils.Vector((1.0, 0, 10.5))
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = camera
    commander_at = mathutils.Vector((-3.6, -9.5, 0))
    cam_data.dof.use_dof = True
    cam_data.dof.focus_distance = (commander_at + mathutils.Vector((0, 0, 3)) - camera.location).length
    cam_data.dof.aperture_fstop = 3.2

    sky()
    icon_lights()
    haze(0.006, -6)
    terrain(scorches=((-0.5, -5.5, 3.5), (-6, 4, 2.5)))

    spawn("commander", BLUE, tuple(commander_at), 40)
    spawn("tiger", BLUE, (-9.5, -4, 0), 70)
    spawn("grunt", BLUE, (-8, 2, 0), 70)

    spawn("juggernaut", RED, (4.2, -1.5, 0), -32)
    spawn("sumo", RED, (9, 3, 0), -60)
    spawn("brute", RED, (11, 10, 0), -70)
    spawn("thor", RED, (15, 20, 0), -60)
    for name, x, y in (("tree", -16, 26), ("tree", -11, 34), ("tree", 20, 30)):
        spawn(name, None, (x, y, 0), random.uniform(0, 360))
    wreck("tiger", (-5.5, 4, 0), 20, smoke=7)

    blast((-0.2, -5.5, 1.0), 1.7, glow=0.6)
    beam((-2.1, -9.3, 3.3), (-0.2, -5.5, 1.4), BLUE_BOLT, width=0.22, name="commander_bolt")
    beam((2.3, -3.3, 7.6), (-0.2, -5.5, 1.4), RED_BOLT, width=0.26)

    team_rim("blue_rim", BLUE, 8.0, (60, 0, 150))
    team_rim("red_rim", RED, 7.0, (60, 0, -145))
    title(camera, ICON_TITLE)
    return camera


def bloom(scene):
    """A glow around the fireball and bolts (Blender 5's compositor node group)."""
    tree = bpy.data.node_groups.new("thumbnail_compositor", "CompositorNodeTree")
    scene.compositing_node_group = tree
    layers = tree.nodes.new("CompositorNodeRLayers")
    glare = tree.nodes.new("CompositorNodeGlare")
    out = tree.nodes.new("NodeGroupOutput")
    tree.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
    for name, value in (("Type", "Bloom"), ("Quality", "High")):
        if name in glare.inputs:
            glare.inputs[name].default_value = value
    for name, value in (("Threshold", 0.9), ("Strength", 0.8), ("Size", 0.65)):
        if name in glare.inputs:
            glare.inputs[name].default_value = value
    tree.links.new(layers.outputs["Image"], glare.inputs["Image"])
    tree.links.new(glare.outputs["Image"], out.inputs[0])


def use_cycles(scene, samples):
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for backend in ("OPTIX", "CUDA", "HIP", "ONEAPI"):
        try:
            prefs.compute_device_type = backend
        except TypeError:
            continue
        prefs.get_devices()
        gpus = [d for d in prefs.devices if d.type == backend]
        if gpus:
            for d in gpus:
                d.use = True
            scene.cycles.device = "GPU"
            break
    scene.cycles.samples = samples
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 6
    print(f"cycles on {scene.cycles.device}")


def overlay_titles(scene, titles, path):
    """Renders just the title, sharp and on a transparent film, and lays it over the image at `path`."""
    import numpy

    hidden = [o for o in scene.objects if o.type != "LIGHT" and o not in titles and not o.hide_render]
    for obj in hidden:
        obj.hide_render = True
    for obj in titles:
        obj.hide_render = False
    scene.camera.data.dof.use_dof = False
    scene.render.film_transparent = True
    title_path = path.replace(".png", "_title.png")
    scene.render.filepath = title_path
    bpy.ops.render.render(write_still=True)

    base = bpy.data.images.load(path)
    top = bpy.data.images.load(title_path)
    size = base.size[0] * base.size[1] * 4
    b = numpy.empty(size, dtype=numpy.float32)
    t = numpy.empty(size, dtype=numpy.float32)
    base.pixels.foreach_get(b)
    top.pixels.foreach_get(t)
    b, t = b.reshape(-1, 4), t.reshape(-1, 4)
    alpha = t[:, 3:4]
    b[:, :3] = t[:, :3] * alpha + b[:, :3] * (1 - alpha)
    base.pixels.foreach_set(b.ravel())
    base.filepath_raw = path
    base.file_format = "PNG"
    base.save()
    Path(title_path).unlink()


def render(args):
    scene = bpy.context.scene
    # both in Cycles: the haze, the team rims (light linking) and the see-through beam shells need it
    use_cycles(scene, args.samples)
    scene.render.resolution_x = args.width
    scene.render.resolution_y = args.height
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = False
    # Standard, for saturated flat colour (AgX greys it all out); the icon is pushed harder, for deeper shadows
    scene.view_settings.view_transform = "Standard"
    try:
        scene.view_settings.look = "High Contrast" if args.shot == "icon" else "Medium High Contrast"
    except TypeError:
        pass
    scene.view_settings.exposure = -0.3 if args.shot == "icon" else 0.0
    bloom(scene)
    scene.render.filepath = args.out
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    titles = [o for o in scene.objects if o.name.startswith("title_")]
    camera = scene.camera.data
    if camera.dof.use_dof:
        # depth of field would blur the title a unit in front of the lens, so it gets its own sharp pass on top
        for obj in titles:
            obj.hide_render = True
    bpy.ops.render.render(write_still=True)
    if camera.dof.use_dof:
        overlay_titles(scene, titles, args.out)
    print(f"wrote {args.out}")
    if args.small:
        # rendered large and scaled down, which antialiases the edges better than rendering small
        image = bpy.data.images.load(args.out)
        image.scale(args.small, args.small)
        image.filepath_raw = args.out.replace("_large", "")
        image.file_format = "PNG"
        image.save()
        print(f"wrote {image.filepath_raw}")


def main():
    args = parse_args()
    if args.probe is not None:
        cast = ["commander", "tiger", "grunt", "valiant", "juggernaut", "thor", "sumo", "brute", "nighthawk"]
        probe(args.probe or cast)
        return
    if args.shot == "icon":
        icon_stage()
    else:
        stage()
    render(args)


if __name__ == "__main__":
    main()
