"""What every generator builds with (in Blender's Python, bpy): the one mesh builder (`mesh`) and face collector
(`Faces`), the shared primitives (rings, blocks, pyramids, ...) every family's shapes are made of, pivots and art
groups, and the paints (`Materials`, over shared/palette.py's colours). A family module keeps only its own shapes."""

import math

import bmesh
import bpy
import mathutils

from . import palette


def new_mesh_object(name):
    mesh = bpy.data.meshes.new(name)
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def mesh(name, verts, faces, origin=(0.0, 0.0, 0.0), recalc_normals=False):
    """An object straight from `verts` (points) and `faces` (tuples of indices into them, each wound counter-
    clockwise seen from the side it shows), built in that order, with its origin at `origin`. With `recalc_normals` Blender
    works out which way each face looks instead. Every shape built vertex by vertex goes through here."""
    obj = new_mesh_object(name)
    bm = bmesh.new()
    made = [bm.verts.new(v) for v in verts]
    for face in faces:
        bm.faces.new([made[i] for i in face])
    if recalc_normals:
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    obj.location = origin
    return obj


def newell(points):
    """A polygon's normal by Newell's method (any number of corners, not normalised): which way it faces."""
    n = mathutils.Vector((0.0, 0.0, 0.0))
    for i, p in enumerate(points):
        q = points[(i + 1) % len(points)]
        n.x += (p[1] - q[1]) * (p[2] + q[2])
        n.y += (p[2] - q[2]) * (p[0] + q[0])
        n.z += (p[0] - q[0]) * (p[1] + q[1])
    return n


class Faces:
    """Faces gathered into one mesh, the one collector every family builds with: points added (moved by a `matrix`
    when one is given, so that a piece can be built flat and hinged into place), and polygons over them, each wound to
    look along `outward` when that is given. With `weld`, a point met again (to five decimals) is the same vertex, and a
    polygon left with fewer than three corners, or with the same corners as one before it, is dropped. The order
    points and faces are added in is the mesh's, which its hash depends on."""

    def __init__(self, weld=False):
        self.points = []
        self.faces = []
        self.weld = weld
        self._welded = {}
        self._seen = set()

    def add(self, points, matrix=None):
        """Adds `points`; returns their indices."""
        indices = []
        for p in points:
            if matrix is not None:
                p = matrix @ mathutils.Vector(p)
            if self.weld:
                key = tuple(round(c, 5) for c in p)
                if key not in self._welded:
                    self._welded[key] = len(self.points)
                    self.points.append(key)
                indices.append(self._welded[key])
            else:
                indices.append(len(self.points))
                self.points.append(mathutils.Vector(p))
        return indices

    def face(self, indices, outward=None):
        """A polygon over points already added, turned round if it does not look along `outward`."""
        indices = list(indices)
        if outward is not None and newell([self.points[i] for i in indices]).dot(mathutils.Vector(outward)) < 0.0:
            indices.reverse()
        if self.weld:
            unique = []
            for i in indices:
                if i not in unique:
                    unique.append(i)
            if len(unique) < 3 or frozenset(unique) in self._seen:
                return self
            self._seen.add(frozenset(unique))
            indices = unique
        self.faces.append(tuple(indices))
        return self

    def polygon(self, points, outward=None, matrix=None):
        """A polygon through new points, which are added the other way round if it would not look along `outward`."""
        points = list(points) if matrix is None else [matrix @ mathutils.Vector(p) for p in points]
        if outward is not None and newell(points).dot(mathutils.Vector(outward)) < 0.0:
            points.reverse()
        return self.face(self.add(points))

    def loft(self, ring_a, ring_b, matrix=None, cap_a=False, cap_b=True, skip=()):
        """The sides between two rings of as many points (a below or behind b, each counter-clockwise seen from b's
        side), and the caps asked for: b's, then a's. `skip` lists sides (side i runs from point i to i + 1) left
        out because nothing sees them."""
        a = self.add(ring_a, matrix)
        b = self.add(ring_b, matrix)
        n = len(a)
        for i in range(n):
            if i not in skip:
                j = (i + 1) % n
                self.face((a[i], a[j], b[j], b[i]))
        if cap_b:
            self.face(b)
        if cap_a:
            self.face(reversed(a))
        return self

    def frustum(self, bottom, top, z0, z1, matrix=None, cap_top=True, cap_bottom=False, skip=()):
        """A prism or frustum between two 2D rings of as many points (counter-clockwise from above), at heights z0
        and z1."""
        return self.loft([(x, y, z0) for x, y in bottom], [(x, y, z1) for x, y in top], matrix, cap_bottom, cap_top, skip)

    def pyramid(self, ring, apex, matrix=None, cap=False):
        """The sides from a ring up to an apex point, and the ring's own face if `cap`."""
        r = self.add(ring, matrix)
        (p,) = self.add([apex], matrix)
        n = len(r)
        for i in range(n):
            self.face((r[i], r[(i + 1) % n], p))
        if cap:
            self.face(reversed(r))
        return self

    def double(self, points, matrix=None):
        """One flat polygon seen from both sides: its back is a face of its own, over points of its own."""
        self.polygon(points, matrix=matrix)
        return self.face(reversed(self.add(points, matrix)))

    def build(self, name, origin=(0.0, 0.0, 0.0)):
        """The object, its points taken as offsets from `origin`, where it is put (see `mesh`)."""
        return mesh(name, self.points, self.faces, origin)

    def build_about(self, name, pivot):
        """The object with its origin at `pivot` (a moving piece's pivot), its points staying where they are."""
        px, py, pz = pivot
        return mesh(name, [(x - px, y - py, z - pz) for x, y, z in self.points], self.faces, pivot)


def set_pivot(obj, point):
    """Moves an object's origin to `point` without moving its mesh, so it can be its art group's pivot."""
    offset = mathutils.Vector(point) - obj.location
    obj.data.transform(mathutils.Matrix.Translation(-offset))
    obj.location = mathutils.Vector(point)
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


def rect(size_x, size_y, centre=(0.0, 0.0)):
    """A rectangle's four corners about `centre`, counter-clockwise from above, from its (-x, -y) corner."""
    hx, hy = size_x / 2.0, size_y / 2.0
    x, y = centre
    return [(x - hx, y - hy), (x + hx, y - hy), (x + hx, y + hy), (x - hx, y + hy)]


def chamfered_rect(size_x, size_y, chamfer, centre=(0.0, 0.0)):
    """An octagon: a rectangle with `chamfer` cut off each corner at 45 degrees, counter-clockwise from above."""
    hx, hy = size_x / 2.0, size_y / 2.0
    c = chamfer
    corners = [(-hx + c, -hy), (hx - c, -hy), (hx, -hy + c), (hx, hy - c), (hx - c, hy), (-hx + c, hy), (-hx, hy - c),
               (-hx, -hy + c)]
    return [(x + centre[0], y + centre[1]) for x, y in corners]


def ngon(sides, radius, phase=0.0, centre=(0.0, 0.0), radius_y=None):
    """`sides` points round a circle (an ellipse, with `radius_y` across Y) about `centre`, counter-clockwise from
    above, the first `phase` radians round from +X."""
    ry = radius if radius_y is None else radius_y
    return [
        (centre[0] + radius * math.cos(phase + 2.0 * math.pi * i / sides),
         centre[1] + ry * math.sin(phase + 2.0 * math.pi * i / sides))
        for i in range(sides)
    ]


def at(points, z):
    """2D points lifted to height `z`."""
    return [(p[0], p[1], z) for p in points]


# A block's faces, by the side each is on (front is -Y), in the order they are built.
BLOCK_FACES = {
    "bottom": (3, 2, 1, 0),
    "top": (4, 5, 6, 7),
    "front": (0, 1, 5, 4),
    "right": (1, 2, 6, 5),
    "back": (2, 3, 7, 6),
    "left": (3, 0, 4, 7),
}


def block(name, size_x, size_y, size_z, top=None, top_offset=(0.0, 0.0), origin=(0.0, 0.0, 0.0), at=(0.0, 0.0, 0.0),
          drop=()):
    """A box standing base-up, or with `top` = (x, y) sizes a frustum whose top is that size, shifted by `top_offset`:
    sloped armour, glacis plates, buttresses. `drop` lists the faces (BLOCK_FACES) never built, because nothing sees
    them. It stands at `origin`, the object's origin; or, built at `at`, it keeps its origin at the world's. 12
    triangles, 2 fewer for each face dropped."""
    tx, ty = (size_x, size_y) if top is None else top
    bx, by, hx, hy = size_x / 2.0, size_y / 2.0, tx / 2.0, ty / 2.0
    ox, oy = top_offset
    x0, y0, z0 = at
    verts = [
        (x0 - bx, y0 - by, z0), (x0 + bx, y0 - by, z0), (x0 + bx, y0 + by, z0), (x0 - bx, y0 + by, z0),
        (x0 + ox - hx, y0 + oy - hy, z0 + size_z), (x0 + ox + hx, y0 + oy - hy, z0 + size_z),
        (x0 + ox + hx, y0 + oy + hy, z0 + size_z), (x0 + ox - hx, y0 + oy + hy, z0 + size_z),
    ]
    return mesh(name, verts, [face for side, face in BLOCK_FACES.items() if side not in drop], origin)


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


def centre_footprint(objects):
    """Moves `objects` on X/Y (Blender) so that their footprint, the first of them (the footing), is centred on the
    origin, the way the game centres an entity's model on its collider: centring on everything would pull a model off
    its collider by half of whatever reaches out past it, like a tower's barrel. build.py does this to every model of a
    category it centres."""
    corners = [objects[0].matrix_world @ mathutils.Vector(corner) for corner in objects[0].bound_box]
    center_x = (min(c.x for c in corners) + max(c.x for c in corners)) / 2
    center_y = (min(c.y for c in corners) + max(c.y for c in corners)) / 2
    if abs(center_x) > 1e-6 or abs(center_y) > 1e-6:
        for obj in objects:
            obj.location.x -= center_x
            obj.location.y -= center_y


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


def drop_faces(obj, indices):
    """Deletes faces by index (a box's bottom where it sits on something, a beam's buried ends). Returns obj."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    bmesh.ops.delete(bm, geom=[bm.faces[i] for i in indices], context="FACES_ONLY")
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def drop_facing(obj, direction, threshold=0.9):
    """Deletes the faces that look along `direction` (world space, e.g. (0, 0, -1) for undersides the RTS
    camera never sees). Returns obj."""
    bpy.context.view_layer.update()
    d = mathutils.Vector(direction).normalized()
    rot = obj.matrix_world.to_3x3()
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.normal_update()
    doomed = [f for f in bm.faces if (rot @ f.normal).normalized().dot(d) > threshold]
    bmesh.ops.delete(bm, geom=doomed, context="FACES_ONLY")
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def pyramid(name, size_x, size_y, height, apex=(0.0, 0.0), origin=(0.0, 0.0, 0.0), base=True):
    """A four-sided pyramid standing on its base (or without it, `base=False`), its apex offset by `apex`: four
    triangles, six with the base. Spikes, pylons, glows."""
    verts = at(rect(size_x, size_y), 0.0) + [(apex[0], apex[1], height)]
    faces = [(i, (i + 1) % 4, 4) for i in range(4)]
    if base:
        faces.append((3, 2, 1, 0))
    return mesh(name, verts, faces, origin)


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


def merge(name, parts, origin=(0.0, 0.0, 0.0)):
    """Joins several already-built objects into one, so a multi-piece assembly (a turret head's
    housing + barrel) exports as a single rotatable MeshPart. Build every part's geometry as a
    local offset from (0, 0, 0) -- that point becomes the merged object's origin, so it can be
    used as a swivel/mount point (e.g. `origin` at the top of a collar, everything else built as
    an offset from there) -- then this moves the whole assembly to `origin` as one rigid unit."""
    target = new_mesh_object(name)
    # The join below keeps material slot order starting from the active object's own slots. If
    # target starts with zero slots, the joined mesh's polygons can end up with no valid slot 0,
    # which build.py's material_of then reads as "no material", flat white. Seeding target's slot 0
    # with the first part's material up front keeps that slot correct after join.
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


def _material(obj, name, color_rgba, emission=0.0, team=False):
    """Gives `obj` the material `name`, made the first time it is asked for: everything the art keeps of it is its
    colour, whether it glows (any `emission`: Neon in the game) and whether it is a `team` material, which takes its
    team's colour in the game as a "Team" part does on a hand-made model (build.py's material_of). Everything of one
    material in one piece is one mesh."""
    mat = bpy.data.materials.get(name)
    if mat is None:
        mat = bpy.data.materials.new(name)
        mat["art_team"] = team
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes["Principled BSDF"]
        bsdf.inputs["Base Color"].default_value = color_rgba
        bsdf.inputs["Emission Color"].default_value = color_rgba
        bsdf.inputs["Emission Strength"].default_value = emission
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


def _colour_tag(color):
    return "".join(f"{round(c * 255):02x}" for c in color[:3])


def paint(obj, color):
    """Paints `obj` a plain `color` (a palette colour, or a def's). Each colour is its own material."""
    _material(obj, f"paint_{_colour_tag(color)}", color)
    return obj


def body_mat(obj):
    return paint(obj, palette.BODY)


def trim_mat(obj):
    return paint(obj, palette.TRIM)


def accent_mat(obj, color):
    """The team accent: `color` (a def's colour) in the build's preview, the team's colour in the game."""
    _material(obj, f"accent_{_colour_tag(color)}", color, team=True)
    return obj


def glow_mat(obj, color):
    """A part that glows, Neon in the game. Each colour is its own material."""
    _material(obj, f"glow_{_colour_tag(color)}", color, emission=1.0)
    return obj


def nano_mat(obj):
    """A nanolathe emitter's glow."""
    return glow_mat(obj, palette.NANO)


def hivis_mat(obj):
    """A builder's high-vis yellow paint."""
    return paint(obj, palette.HIVIS)


class Materials:
    """One model's paints, by what each is for (KINDS): the shared body, trim and high-vis yellow, the model's team
    accent (its def's colour, the team's in the game) and its glow. Each paints an object and returns it; `paint` paints
    any number by the kind's name, as the face collectors do."""

    KINDS = ("body", "trim", "accent", "glow", "hivis")

    def __init__(self, accent, glow=palette.AMBER):
        self.accent_color = accent
        self.glow_color = glow

    def body(self, obj):
        return body_mat(obj)

    def trim(self, obj):
        return trim_mat(obj)

    def hivis(self, obj):
        return hivis_mat(obj)

    def accent(self, obj):
        return accent_mat(obj, self.accent_color)

    def glow(self, obj, color=None):
        """The model's glow, or another `color` of glow."""
        return glow_mat(obj, self.glow_color if color is None else color)

    def paint(self, kind, *objects):
        """Paints every one of `objects` the paint called `kind`, and returns them as a list."""
        assert kind in self.KINDS, kind
        for obj in objects:
            getattr(self, kind)(obj)
        return list(objects)
