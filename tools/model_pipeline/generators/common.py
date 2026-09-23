"""Shared helpers for procedural generators. Runs inside Blender's Python (bpy)."""

import math

import bmesh
import bpy

# The palette every generator shares: gunmetal body panels and near-black trim (footings,
# collars, braces). Each family adds its own accent from its unit_defs color, plus a glow.
BODY_COLOR = (0.40, 0.40, 0.43, 1.0)
TRIM_COLOR = (0.17, 0.17, 0.19, 1.0)


def new_mesh_object(name):
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def box(name, size_x, size_y, size_z, origin=(0.0, 0.0, 0.0)):
    """A box centered on X/Z at origin, sitting base-up from origin[1] (Blender Z-up)."""
    obj = new_mesh_object(name)
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=1.0)
    bmesh.ops.scale(bm, vec=(size_x, size_y, size_z), verts=bm.verts)
    bmesh.ops.translate(bm, vec=(0.0, 0.0, size_z / 2.0), verts=bm.verts)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def gabled_roof(name, width, depth, ridge_height, origin=(0.0, 0.0, 0.0)):
    """A simple prism roof: rectangular base, ridge running along X at the peak."""
    obj = new_mesh_object(name)
    bm = bmesh.new()
    hw, hd = width / 2.0, depth / 2.0
    v0 = bm.verts.new((-hw, -hd, 0.0))
    v1 = bm.verts.new((hw, -hd, 0.0))
    v2 = bm.verts.new((hw, hd, 0.0))
    v3 = bm.verts.new((-hw, hd, 0.0))
    v4 = bm.verts.new((-hw, 0.0, ridge_height))
    v5 = bm.verts.new((hw, 0.0, ridge_height))
    bm.faces.new((v0, v1, v5, v4))
    bm.faces.new((v2, v3, v4, v5))
    bm.faces.new((v0, v4, v3))
    bm.faces.new((v1, v2, v5))
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def flat_roof(name, width, depth, thickness, origin=(0.0, 0.0, 0.0)):
    return box(name, width, depth, thickness, origin=origin)


def cylinder(name, radius, depth, origin=(0.0, 0.0, 0.0), segments=18, radius2=None):
    """A cylinder (or, with radius2, a truncated cone) standing base-up from origin."""
    obj = new_mesh_object(name)
    bm = bmesh.new()
    bmesh.ops.create_cone(
        bm,
        cap_ends=True,
        cap_tris=False,
        segments=segments,
        radius1=radius,
        radius2=radius if radius2 is None else radius2,
        depth=depth,
    )
    bmesh.ops.translate(bm, vec=(0.0, 0.0, depth / 2.0), verts=bm.verts)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def tapered_box(name, size_x, size_y, size_z, top_x, top_y, top_offset=(0.0, 0.0), origin=(0.0, 0.0, 0.0)):
    """A box whose top face is a different size (top_x, top_y) and can be shifted by top_offset,
    standing base-up from origin: sloped armor, glacis plates, buttresses."""
    obj = new_mesh_object(name)
    bm = bmesh.new()
    bx, by = size_x / 2.0, size_y / 2.0
    tx, ty = top_x / 2.0, top_y / 2.0
    ox, oy = top_offset
    bottom = [bm.verts.new(c) for c in ((-bx, -by, 0.0), (bx, -by, 0.0), (bx, by, 0.0), (-bx, by, 0.0))]
    top = [
        bm.verts.new(c)
        for c in (
            (ox - tx, oy - ty, size_z),
            (ox + tx, oy - ty, size_z),
            (ox + tx, oy + ty, size_z),
            (ox - tx, oy + ty, size_z),
        )
    ]
    bm.faces.new(list(reversed(bottom)))
    bm.faces.new(top)
    for i in range(4):
        j = (i + 1) % 4
        bm.faces.new((bottom[i], bottom[j], top[j], top[i]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def octagon(name, radius, height, z=0.0, radius2=None, xy=(0.0, 0.0)):
    """An 8-sided prism/frustum turned so its flats, not its corners, face the axes. Its
    flat-to-flat width is 2 * radius * cos(22.5deg), about 1.85 * radius."""
    obj = cylinder(name, radius, height, origin=(xy[0], xy[1], z), segments=8, radius2=radius2)
    obj.rotation_euler = (0.0, 0.0, math.radians(22.5))
    return obj


def torus(name, major_radius, minor_radius, origin=(0.0, 0.0, 0.0), segments=32, ring_segments=8):
    """A ring lying flat in the XY plane around origin; rotate it to stand it up."""
    obj = new_mesh_object(name)
    bm = bmesh.new()
    rows = []
    for i in range(segments):
        a = 2.0 * math.pi * i / segments
        row = []
        for j in range(ring_segments):
            b = 2.0 * math.pi * j / ring_segments
            r = major_radius + minor_radius * math.cos(b)
            row.append(bm.verts.new((r * math.cos(a), r * math.sin(a), minor_radius * math.sin(b))))
        rows.append(row)
    for i in range(segments):
        a_row, b_row = rows[i], rows[(i + 1) % segments]
        for j in range(ring_segments):
            k = (j + 1) % ring_segments
            bm.faces.new((a_row[j], b_row[j], b_row[k], a_row[k]))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def strut(name, size_x, size_y, length, start, tilt_x=0.0, tilt_y=0.0):
    """A box of cross-section size_x by size_y running `length` from `start`, tipped from
    vertical by tilt_x degrees about X (positive leans toward -Y, the front) and then tilt_y
    about Y (positive leans toward +X). Returns (obj, end_point) so struts can be chained."""
    obj = box(name, size_x, size_y, length)
    ax, ay = math.radians(tilt_x), math.radians(tilt_y)
    obj.rotation_euler = (ax, ay, 0.0)
    obj.location = start
    # R = Ry(ay) @ Rx(ax) applied to +Z (Blender's XYZ euler order).
    dx, dy, dz = 0.0, -math.sin(ax), math.cos(ax)
    dx, dz = dx * math.cos(ay) + dz * math.sin(ay), -dx * math.sin(ay) + dz * math.cos(ay)
    end = (start[0] + dx * length, start[1] + dy * length, start[2] + dz * length)
    return obj, end


def drop_bottom(obj):
    """Deletes the faces on an object's underside -- the downward-facing ones at its lowest height -- which are never
    seen on something standing on the ground or on another part. Two triangles saved on a box. Returns obj."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.normal_update()
    lowest = min(v.co.z for v in bm.verts)
    hidden = [f for f in bm.faces if f.normal.z < -0.99 and all(abs(v.co.z - lowest) < 1e-5 for v in f.verts)]
    bmesh.ops.delete(bm, geom=hidden, context="FACES_ONLY")
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def pyramid(name, size_x, size_y, height, apex=(0.0, 0.0), origin=(0.0, 0.0, 0.0), base=True):
    """A four-sided pyramid standing on its base (or without it, `base=False`), its apex offset by `apex`: four
    triangles, six with the base. Spikes, pylons, glows."""
    obj = new_mesh_object(name)
    bm = bmesh.new()
    bx, by = size_x / 2.0, size_y / 2.0
    corners = [bm.verts.new(c) for c in ((-bx, -by, 0.0), (bx, -by, 0.0), (bx, by, 0.0), (-bx, by, 0.0))]
    top = bm.verts.new((apex[0], apex[1], height))
    for i in range(4):
        bm.faces.new((corners[i], corners[(i + 1) % 4], top))
    if base:
        bm.faces.new(list(reversed(corners)))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def octahedron(name, radius, origin=(0.0, 0.0, 0.0)):
    """The cheapest thing that reads as a ball: eight triangles."""
    obj = new_mesh_object(name)
    bm = bmesh.new()
    r = radius
    px, nx = bm.verts.new((r, 0, 0)), bm.verts.new((-r, 0, 0))
    py, ny = bm.verts.new((0, r, 0)), bm.verts.new((0, -r, 0))
    pz, nz = bm.verts.new((0, 0, r)), bm.verts.new((0, 0, -r))
    for a, b in ((px, py), (py, nx), (nx, ny), (ny, px)):
        bm.faces.new((a, b, pz))
        bm.faces.new((b, a, nz))
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def band(name, radius, height, segments=6, origin=(0.0, 0.0, 0.0), thickness=None):
    """An open ring: the side walls of a `segments`-sided prism with no caps, lying flat in the XY plane around
    origin and `height` tall, seen from inside and out (a second wall `thickness` in, default 6% of the radius).
    4 * segments triangles. Rotate it to stand it up."""
    obj = new_mesh_object(name)
    bm = bmesh.new()
    inner = radius - (thickness if thickness is not None else radius * 0.06)
    h = height / 2.0
    rings = []
    for r in (radius, inner):
        low, high = [], []
        for i in range(segments):
            a = 2.0 * math.pi * i / segments
            low.append(bm.verts.new((r * math.cos(a), r * math.sin(a), -h)))
            high.append(bm.verts.new((r * math.cos(a), r * math.sin(a), h)))
        rings.append((low, high))
    for wall, (low, high) in enumerate(rings):
        for i in range(segments):
            j = (i + 1) % segments
            quad = (low[i], low[j], high[j], high[i])
            bm.faces.new(quad if wall == 0 else tuple(reversed(quad)))
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def sphere(name, radius, origin=(0.0, 0.0, 0.0), segments=12):
    obj = new_mesh_object(name)
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=segments, v_segments=segments // 2, radius=radius)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def merge(name, parts, origin=(0.0, 0.0, 0.0)):
    """Joins several already-built objects into one, so a multi-piece assembly (a turret head's
    housing + barrel) exports as a single rotatable MeshPart. Build every part's geometry as a
    local offset from (0, 0, 0) -- that point becomes the merged object's origin, so it can be
    used as a swivel/mount point (e.g. `origin` at the top of a collar, everything else built as
    an offset from there) -- then this moves the whole assembly to `origin` as one rigid unit."""
    target = new_mesh_object(name)
    # The join below keeps material slot order starting from the active object's own slots. If
    # target starts with zero slots, the joined mesh's polygons can end up with no valid slot 0,
    # which object_to_part_data() then reads as "no material" and exports as flat white. Seeding
    # target's slot 0 with the first part's material up front keeps that slot correct after join.
    if parts and parts[0].data.materials:
        target.data.materials.append(parts[0].data.materials[0])

    bpy.context.view_layer.objects.active = target
    bpy.ops.object.select_all(action="DESELECT")
    for part in parts:
        part.select_set(True)
    target.select_set(True)
    bpy.ops.object.join()
    target.location = origin
    return target


def apply_material(obj, name, color_rgba, roughness=0.55, metallic=0.0, emission=0.0):
    """A PBR material with a bit of procedural roughness variation baked in via noise, so flat
    faces don't read as flawless plastic. `emission` is a 0-1 strength for glowing parts (lenses,
    beacons); `metallic` for bare metal vs. painted panels."""
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        nodes = mat.node_tree.nodes
        links = mat.node_tree.links
        bsdf = nodes.get("Principled BSDF")
        if bsdf is not None:
            bsdf.inputs["Base Color"].default_value = color_rgba
            bsdf.inputs["Metallic"].default_value = metallic
            if "Emission Color" in bsdf.inputs:
                bsdf.inputs["Emission Color"].default_value = color_rgba
            if "Emission Strength" in bsdf.inputs:
                bsdf.inputs["Emission Strength"].default_value = emission

            noise = nodes.new("ShaderNodeTexNoise")
            noise.inputs["Scale"].default_value = 12.0
            noise.inputs["Detail"].default_value = 4.0
            map_range = nodes.new("ShaderNodeMapRange")
            map_range.inputs["To Min"].default_value = max(roughness - 0.12, 0.05)
            map_range.inputs["To Max"].default_value = min(roughness + 0.12, 1.0)
            links.new(noise.outputs["Fac"], map_range.inputs["Value"])
            links.new(map_range.outputs["Result"], bsdf.inputs["Roughness"])
    obj.data.materials.append(mat)


def art_group(obj, group, pivot=False, **meta):
    """Puts `obj` in rigid piece `group` of the exported art (build.py's collect_groups): everything in one piece
    moves together in the game, about the location of whichever of its objects is the `pivot`. `meta` says how
    it moves, for src/client/art.luau: kind="turret" with weapon=<index> follows that weapon's aim, kind="work"
    turns toward what a builder is working on, kind="spin" turns about `axis` (Blender coordinates) at `speed`
    radians a second, and kind="leg" swings back and forth about `axis` through its pivot (the hip), `swing` radians
    either way, while the unit walks: once per `stride` studs it covers, `phase` (0 to 1) of a cycle apart from its
    other legs. kind="wheel" rolls about `axis` through its pivot (the hub) as the unit drives, by the distance
    covered over its `radius`. kind="hatch" with weapon=<index> swings `open` radians about `axis` (its hinge) when
    that weapon fires, and closes again a moment later. A kind="turret" piece's muzzle, where its weapon fires
    from, is the point of it that reaches furthest forward (build.py's muzzle_of). Returns obj."""
    obj["art_group"] = group
    if pivot:
        obj["art_pivot"] = True
    for key, value in meta.items():
        obj[f"art_{key}"] = value
    return obj


def body_mat(obj):
    apply_material(obj, "shared_body", BODY_COLOR, roughness=0.42, metallic=0.7)


def trim_mat(obj):
    apply_material(obj, "shared_trim", TRIM_COLOR, roughness=0.5, metallic=0.6)


def finish_all(objects, max_bevel=0.03):
    """finalize() + smart_uv() on every object, with a bevel scaled to each part's own size so a
    small piece doesn't get eaten alive. Bigger buildings pass a bigger max_bevel."""
    for obj in objects:
        smallest_dim = min(d for d in obj.dimensions if d > 1e-6)
        finalize(obj, bevel_width=min(max_bevel, smallest_dim * 0.08))
        smart_uv(obj)
    return objects


def smart_uv(obj):
    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=66.0, island_margin=0.02)
    bpy.ops.object.mode_set(mode="OBJECT")


def finalize(obj, bevel_width=0.015, bevel_segments=1, shade_smooth=True):
    """Bevel + smooth shading so hard-surface parts catch light like machined edges instead of
    flat CAD blocks. Call once per object after its geometry and material are set."""
    bevel = obj.modifiers.new("Bevel", type="BEVEL")
    bevel.width = bevel_width
    bevel.segments = bevel_segments
    bevel.limit_method = "ANGLE"
    bevel.angle_limit = 0.7853982  # 45 degrees: round hard edges, leave soft ones alone

    bpy.context.view_layer.objects.active = obj
    bpy.ops.object.modifier_apply(modifier=bevel.name)

    if shade_smooth:
        try:
            bpy.ops.object.shade_smooth_by_angle(angle=0.6981317)  # 40 degrees, Blender 4.1+
        except AttributeError:
            bpy.ops.object.shade_smooth()
