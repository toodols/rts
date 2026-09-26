"""unit_defs/air_t1.luau `hephaestus` (BAR corseah): the heavy transport.

Faceted low-poly, under 100
triangles. A slow flying crane, as unlike the Hercules as it can be: one long, deep, squared hull with a
cockpit on its nose, two big engine nacelles hugging its flanks with glowing exhausts, a pair of dark cargo
claws hanging under the belly, and a huge three-bladed lift rotor on a mast on its back. The rotor and the
nacelles are the team-coloured accent; the rotor spins (kind "spin" about Blender Z).
"""

import math

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "hephaestus"


def generate(params):
    accent = params["color"]
    zc = 2.05
    objects = []

    hull = air.loft("hull", [
        (-2.60, zc - 0.15, 0.60, 0.45),
        (-1.55, zc, 1.30, 0.92),
        (1.80, zc + 0.05, 1.25, 0.86),
        (2.60, zc + 0.10, 0.80, 0.55),
    ], sides=4)
    common.body_mat(hull)
    objects.append(hull)

    canopy = air.poly("canopy", [
        (0.0, -2.52, zc + 0.24),
        (0.62, -1.72, zc + 0.64),
        (-0.62, -1.72, zc + 0.64),
        (0.0, -1.62, zc + 0.90),
    ], [(0, 1, 3), (0, 3, 2), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    accents, glows, trims = [], [], []
    hw = 1.25 * 0.7071  # the hull's half width at its widest
    for side in (-1.0, 1.0):
        x = side * (hw + 0.40)
        nacelle = air.beam(f"nacelle_{side:+.0f}", (x, -0.40, zc - 0.05), (x, 2.45, zc + 0.05), 0.85, 0.80,
                           top_scale=0.72)
        accents.append(nacelle)
        trims.append(air.plate(f"intake_{side:+.0f}", (x, -0.41, zc - 0.05), (0.36, 0, 0), (0, 0, 0.34), (0, -1, 0)))
        glows.append(air.plate(f"exhaust_{side:+.0f}", (x, 2.46, zc + 0.05), (0.26, 0, 0), (0, 0, 0.24), (0, 1, 0)))

    # Cargo claws: two dark tapered jaws under the belly, open on top against the hull.
    bottom = zc - 0.86 * 0.7071
    for side in (-1.0, 1.0):
        jaw = common.block(f"claw_{side:+.0f}", 0.16, 1.9, 0.95, top=(0.34, 2.6), top_offset=(side * 0.18, 0.0), origin=(side * 0.42, 0.1, bottom - 0.93))
        common.drop_faces(jaw, [1])
        trims.append(jaw)

    # Rotor mast on the hull's back.
    top = zc + 0.86 * 0.7071
    mast = common.drop_bottom(common.block("mast", 0.60, 0.80, 0.55, top=(0.36, 0.44), origin=(0.0, 0.25, top - 0.02)))
    trims.append(mast)

    for obj in accents:
        common.accent_mat(obj, accent)
    for obj in glows:
        common.glow_mat(obj, palette.JET_EXHAUST)
    for obj in trims:
        common.trim_mat(obj)
    objects += accents + glows + trims

    # The lift rotor: three long flat paddles meeting at the mast head, spinning together about it.
    hub = (0.0, 0.25, top + 0.55)
    blade_len, chord = 3.25, 0.40
    blades = []
    for i in range(3):
        a = math.radians(90.0 + 120.0 * i)
        ca, sa = math.cos(a), math.sin(a)
        blade_len_i = blade_len
        # a paddle from the hub outward: two triangles, looking up
        c = (hub[0] + ca * blade_len_i / 2.0, hub[1] + sa * blade_len_i / 2.0, hub[2])
        blades.append(air.plate(f"rotor_{i}", c, (ca * blade_len_i / 2.0, sa * blade_len_i / 2.0, 0.0),
                                (-sa * chord / 2.0, ca * chord / 2.0, 0.0), (0, 0, 1)))
    for b in blades:
        common.accent_mat(b, accent)
        objects.append(common.art_group(b, "rotor"))
    # the pivot marker has to sit on the axis: an extra blade-free object would cost a part, so the first
    # blade's origin is moved onto the hub and its vertices shifted to match
    first = blades[0]
    offset = [first.location[k] - hub[k] for k in range(3)]
    for v in first.data.vertices:
        v.co.x += offset[0]
        v.co.y += offset[1]
        v.co.z += offset[2]
    first.location = hub
    common.art_group(first, "rotor", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=9.0)

    return objects
