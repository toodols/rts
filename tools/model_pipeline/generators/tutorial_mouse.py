"""Tutorial UI icon: a computer mouse lying flat, its buttons toward -Z (Roblox; away from a camera toward +Z looking
down), for teaching clicks and the wheel.

Art groups: `button_left` and `button_right` (the two light button shells, left and right as the viewer sees them),
`wheel` (the middle wheel/button) and the dark shell as `base`. The origin is the middle of its footprint, on the
ground. Written to src/shared/ui_art/, not src/shared/art/.
"""

import math

import bmesh

from . import common
from . import tutorial_common as tc

MAX_TRIANGLES = tc.MAX_TRIANGLES
RECENTRE = False

SHELL_COLOR = (0.15, 0.15, 0.17, 1.0)
BUTTON_COLOR = (0.62, 0.63, 0.66, 1.0)
WHEEL_COLOR = (0.36, 0.37, 0.40, 1.0)

HALF_WIDTH = 1.25
FRONT = 2.05  # from the dome's peak to the front edge (Blender +Y)
BACK = 1.85  # and to the back
PEAK_Y = -0.1  # the dome peaks a little behind the middle, like a palm rest
SKIRT = 0.28  # the straight side wall below the dome
DOME = 1.0
SQUARENESS = 2.6
SEGMENTS = 20
BUTTON_GAP = 0.17  # half the slot between the buttons, where the wheel sits
BUTTON_LIFT = 0.045


def outline(theta):
    """The footprint's edge at angle theta about the peak: a squarish egg, a little narrower at the front."""
    c, s = math.cos(theta), math.sin(theta)
    e = 2.0 / SQUARENESS
    x = math.copysign(abs(c) ** e, c) * HALF_WIDTH * (1.0 - 0.12 * max(0.0, s))
    y = math.copysign(abs(s) ** e, s) * (FRONT if s > 0 else BACK)
    return x, y


def height(r):
    """The shell's height a fraction r of the way from its peak out to its edge."""
    return SKIRT + DOME * max(0.0, 1.0 - r ** 2.4) ** 0.55


def surface(theta, r, lift=0.0):
    x, y = outline(theta)
    return (x * r, PEAK_Y + y * r, height(r) + lift)


def shell():
    obj = common.new_mesh_object("shell")
    bm = bmesh.new()
    rings = [(1.0, 0.0), (1.0, SKIRT)] + [(r, height(r)) for r in (0.93, 0.8, 0.6, 0.34)]
    thetas = [2.0 * math.pi * i / SEGMENTS for i in range(SEGMENTS)]
    verts = []
    for r, z in rings:
        verts.append([bm.verts.new((outline(t)[0] * r, PEAK_Y + outline(t)[1] * r, z)) for t in thetas])
    apex = bm.verts.new((0.0, PEAK_Y, height(0.0)))
    for a, b in zip(verts, verts[1:]):
        for i in range(SEGMENTS):
            j = (i + 1) % SEGMENTS
            bm.faces.new((a[i], a[j], b[j], b[i]))
    for i in range(SEGMENTS):
        bm.faces.new((verts[-1][i], verts[-1][(i + 1) % SEGMENTS], apex))
    bm.faces.new(list(reversed(verts[0])))  # the bottom, dropped below: keeps the normals' recalc closed
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    common.drop_bottom(obj)
    return obj


def _bisect(f, lo, hi, steps=40):
    """The root of f, increasing across [lo, hi]."""
    for _ in range(steps):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if f(mid) < 0 else (lo, mid)
    return (lo + hi) / 2


def height_at(x, y):
    """The shell's height over footprint point (x, y): which ring fraction r of which outline angle passes there."""
    px, py = x, y - PEAK_Y
    if abs(px) < 1e-9 and abs(py) < 1e-9:
        return height(0.0)
    want = math.atan2(py, px)
    # the outline's direction turns steadily with theta, so find the theta pointing the same way
    def off(t):
        a = math.atan2(outline(t)[1], outline(t)[0]) - want
        return math.atan2(math.sin(a), math.cos(a))

    theta = _bisect(off, want - 0.6, want + 0.6)
    ox, oy = outline(theta)
    return height(math.hypot(px, py) / math.hypot(ox, oy))


def edge_x(y, reach):
    """How far out to the side (+X) the footprint reaches at y, taken `reach` of the way to its edge."""
    top = PEAK_Y + FRONT * reach
    y = min(y, top - 1e-4)
    theta = _bisect(lambda t: PEAK_Y + outline(t)[1] * reach - y, 0.0, math.pi / 2)
    return outline(theta)[0] * reach


def button(name, side, columns=5, rows=5):
    """One button: a thin shell hugging the front half of the mouse on one side, from the middle slot out to its
    side edge, and from across the peak to near the front edge."""
    reach = 0.94
    y0 = PEAK_Y + 0.08
    y1 = PEAK_Y + FRONT * reach * 0.985
    obj = common.new_mesh_object(name)
    bm = bmesh.new()
    top, low = [], []
    for j in range(rows + 1):
        # rows bunch toward the front, where the edge curves in fastest
        f = j / rows
        y = y0 + (y1 - y0) * (1.0 - (1.0 - f) ** 1.6)
        outer = max(edge_x(y, reach), BUTTON_GAP + 0.02)
        top_row, low_row = [], []
        for i in range(columns + 1):
            x = side * (BUTTON_GAP + (outer - BUTTON_GAP) * i / columns)
            h = height_at(x, y)
            top_row.append(bm.verts.new((x, y, h + BUTTON_LIFT)))
            low_row.append(bm.verts.new((x, y, h - 0.08)))
        top.append(top_row)
        low.append(low_row)
    for j in range(rows):
        for i in range(columns):
            bm.faces.new((top[j][i], top[j][i + 1], top[j + 1][i + 1], top[j + 1][i]))
    # side walls down into the shell, all the way round the patch
    ring = (
        [(j, 0) for j in range(rows + 1)]
        + [(rows, i) for i in range(1, columns + 1)]
        + [(j, columns) for j in range(rows - 1, -1, -1)]
        + [(0, i) for i in range(columns - 1, 0, -1)]
    )
    for k in range(len(ring)):
        (j0, i0), (j1, i1) = ring[k], ring[(k + 1) % len(ring)]
        bm.faces.new((top[j0][i0], top[j1][i1], low[j1][i1], low[j0][i0]))
    # the bottom corners inside the patch are unused
    bmesh.ops.delete(bm, geom=[v for v in bm.verts if not v.link_faces], context="VERTS")
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    bm.normal_update()
    top_faces = [f for f in bm.faces if all(v.co.z > 0 and v in set(sum(top, [])) for v in f.verts)]
    if sum(f.normal.z for f in top_faces) < 0:
        bmesh.ops.reverse_faces(bm, faces=bm.faces)
    bm.to_mesh(obj.data)
    bm.free()
    return obj


def generate(params):
    base = tc.mat(shell(), "mouse_shell", SHELL_COLOR, roughness=0.45)

    left = tc.mat(button("button_left", -1), "mouse_button", BUTTON_COLOR, roughness=0.5)
    right = tc.mat(button("button_right", 1), "mouse_button", BUTTON_COLOR, roughness=0.5)
    common.art_group(left, "button_left")
    common.art_group(right, "button_right")

    # the wheel stands on its edge in the slot, turning about X, a third of it showing above the shell
    r = 0.38
    wy = PEAK_Y + FRONT * r
    radius = 0.36
    wz = height(r) - radius * 0.4
    wheel = common.cylinder("wheel", radius, 0.24, segments=10)
    for v in wheel.data.vertices:
        v.co.z -= 0.12
    wheel.rotation_euler = (0.0, math.radians(90.0), 0.0)
    wheel.location = (0.0, wy, wz)
    tc.mat(wheel, "mouse_wheel", WHEEL_COLOR, roughness=0.6)
    common.art_group(wheel, "wheel", pivot=True)
    return [base, left, right, wheel]
