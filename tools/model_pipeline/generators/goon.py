"""unit_defs/hover_t1.luau `goon` (BAR corsh): Cortex's fast, flimsy raider hovercraft.

A narrow, pointed wedge on a dark rubber
skirt, in under 100 triangles: the skirt is a flared apron a little wider than the hull (no underside), the hull a
low armoured wedge rising from it, one ducted fan standing on the stern with a static blade cross in it, and a
small team-coloured wedge turret amidships carrying one thin laser barrel with a yellow emitter at its tip, so it
reads as small, sleek and quick.

The unit faces Blender -Y (Roblox +Z). Origin = ground, centred on the footprint.
"""

import math

from .shared import common
from .shared import palette
from .shared import polygons
from .shared import ship_t1 as ship
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "goon"
MOUNTS = {
    1: {"pivot": (0, 0.6431, -0.0517), "muzzle": (0, 0.1263, 1.2707)},
}


def skirt_mat(obj):
    common.paint(obj, palette.SKIRT)
    return obj


def _scaled(outline, k, dy=0.0):
    return [(x * k, y * k + dy) for x, y in outline]


def generate(params):
    accent = params["color"]
    objects = []

    # Skirt (the footprint object): a pointed apron flaring out from its foot, top closed. 19 triangles.
    plan = [(0.0, -1.32), (0.52, -0.92), (0.8, -0.2), (0.8, 1.22), (-0.8, 1.22), (-0.8, -0.2), (-0.52, -0.92)]
    skirt_h = 0.2
    skirt = ship.prism("skirt", _scaled(plan, 0.92, 0.02), skirt_h, top_outline=plan, origin=(0.0, 0.0, 0.04))
    objects.append(skirt_mat(skirt))

    # Hull: a low wedge rising from the skirt, the nose raked well back. 19 triangles.
    z0 = 0.04 + skirt_h
    top_z, nose_z = 0.56, 0.44
    lo = [(x, y, z0) for x, y in _scaled(plan, 0.88, 0.04)]
    hi = [
        (0.0, -0.8, nose_z), (0.3, -0.58, nose_z + 0.04), (0.5, -0.05, top_z), (0.5, 1.02, top_z),
        (-0.5, 1.02, top_z), (-0.5, -0.05, top_z), (-0.3, -0.58, nose_z + 0.04),
    ]
    if polygons.signed_area([(x, y) for x, y, _ in lo]) < 0:
        lo, hi = list(reversed(lo)), list(reversed(hi))
    hull = ship.loft("hull", [lo, hi], cap_first=False, cap_last=True)
    objects.append(common.body_mat(hull))

    # Ducted fan on the stern: a six-sided ring standing up, flat side down on the deck. 24 triangles.
    r = 0.42
    duct_y = 0.86
    duct_c = (0.0, duct_y, top_z + r * math.sin(math.radians(60)) - 0.1)
    duct = common.band("duct", r, 0.2, segments=6, origin=duct_c, thickness=0.07)
    duct.rotation_euler = (math.pi / 2.0, 0.0, 0.0)
    objects.append(common.accent_mat(duct, accent))

    # Static fan blades: an X of two thin double-sided blades inside the ring. 8 triangles.
    cx, cy, cz = duct_c
    br, bw = r * 0.86, 0.05
    blades = []
    for k, a in enumerate((math.radians(45), math.radians(135))):
        ca, sa = math.cos(a), math.sin(a)
        nx, nz = -sa * bw, ca * bw
        pts = [
            (cx - ca * br - nx, cy, cz - sa * br - nz), (cx + ca * br - nx, cy, cz + sa * br - nz),
            (cx + ca * br + nx, cy, cz + sa * br + nz), (cx - ca * br + nx, cy, cz - sa * br + nz),
        ]
        blades.append(common.trim_mat(ship.fin(f"blade_{k}", pts)))
    objects.append(common.merge("fan", blades))

    # Small wedge turret amidships, about its ring: 14 triangles.
    pivot = (0.0, 0.0, top_z)
    turret = v.prism(
        "turret",
        [(-0.32, 0.0), (-0.16, 0.19), (0.24, 0.21), (0.32, 0.1), (0.32, 0.0)],
        width_bottom=0.56,
        width_top=0.36,
        origin=pivot,
    )
    common.accent_mat(turret, accent)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # Thin laser barrel, its back buried in the turret: 10 triangles.
    barrel, tip = v.beam("barrel", 0.08, 0.08, 0.95, (0.0, -0.14, 0.11), top_scale=0.7)
    common.trim_mat(barrel)
    barrel = common.merge("barrel_m", [barrel], origin=pivot)
    objects.append(common.art_group(barrel, "turret_1"))

    # Yellow emitter tip: 4 triangles.
    lens = v.spike("lens", 0.055, 0.14, (pivot[0], pivot[1] + tip[1], pivot[2] + tip[2]))
    common.glow_mat(lens, palette.LASER_YELLOW)
    objects.append(common.art_group(lens, "turret_1"))

    return objects
