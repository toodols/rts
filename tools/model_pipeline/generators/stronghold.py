"""unit_defs/air_t2.luau `stronghold`: the heavy transport gunship.

Faceted low-poly, under 100
triangles. A tandem-rotor heavy lifter with guns: one long squared hull with a glazed cockpit, a dark gun barrel under
the chin (its fast laser), a missile pod on either flank (its anti air missiles), a pair of dark cargo jaws under the
belly, and two big three-bladed rotors, fore and aft on masts, that spin opposite ways. The rotors are the team-coloured
accent.
"""

import math

from .shared import air_t1 as air
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "stronghold"
# an aircraft's BAR collision volume is only its fuselage's: the rest of it reaches past, as BAR's model does
ENVELOPE = {"length": 7.9, "height": 3.63}


def rotor(objects, name, hub, blade_len, chord, speed, turn, accent):
    """Three flat paddles meeting at `hub`, spinning together about it (Blender Z) at `speed`."""
    blades = []
    for i in range(3):
        a = math.radians(turn + 120.0 * i)
        ca, sa = math.cos(a), math.sin(a)
        c = (hub[0] + ca * blade_len / 2.0, hub[1] + sa * blade_len / 2.0, hub[2])
        blades.append(air.plate(f"{name}_{i}", c, (ca * blade_len / 2.0, sa * blade_len / 2.0, 0.0),
                                (-sa * chord / 2.0, ca * chord / 2.0, 0.0), (0, 0, 1)))
    for blade in blades:
        common.accent_mat(blade, accent)
        objects.append(common.art_group(blade, name))
    # the pivot has to sit on the axis, so the first blade's origin is moved onto the hub and its vertices to match
    first = blades[0]
    offset = [first.location[k] - hub[k] for k in range(3)]
    for v in first.data.vertices:
        v.co.x += offset[0]
        v.co.y += offset[1]
        v.co.z += offset[2]
    first.location = hub
    common.art_group(first, name, pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=speed)


def generate(params):
    accent = params["color"]
    zc = 2.00
    objects = []

    hull = air.loft("hull", [
        (-3.20, zc - 0.20, 0.70, 0.55),
        (-2.00, zc, 1.20, 0.95),
        (3.20, zc + 0.10, 1.05, 0.80),
    ], sides=4)
    common.body_mat(hull)
    objects.append(hull)

    canopy = air.poly("canopy", [
        (0.0, -3.05, zc + 0.30),
        (0.60, -2.20, zc + 0.62),
        (-0.60, -2.20, zc + 0.62),
        (0.0, -2.05, zc + 0.92),
    ], [(0, 1, 3), (0, 3, 2), (1, 2, 3)])
    air.glass_mat(canopy)
    objects.append(canopy)

    trims = []
    # The chin gun: a long dark spike under the nose.
    trims.append(air.tetra("gun", (0.0, -3.95, zc - 0.55), (-0.18, -2.30, zc - 0.40), (0.18, -2.30, zc - 0.40),
                           (0.0, -2.30, zc - 0.75)))
    hw = 1.20 * 0.7071
    for side in (-1.0, 1.0):
        # a missile pod on each flank
        x = side * (hw + 0.10)
        trims.append(air.tetra(f"pod_{side:+.0f}", (x + side * 0.05, -1.60, zc - 0.10),
                               (x + side * 0.55, 0.40, zc + 0.15), (x + side * 0.55, 0.40, zc - 0.35),
                               (x + side * 0.02, 0.40, zc - 0.10)))
        # a cargo jaw under the belly
        trims.append(air.tetra(f"jaw_{side:+.0f}", (side * 0.40, -0.90, zc - 0.60), (side * 0.40, 1.30, zc - 0.60),
                               (side * 0.70, 0.20, zc - 1.55), (side * 0.10, 0.20, zc - 0.70)))
    glows = [air.plate("exhaust", (0.0, 3.21, zc + 0.10), (0.45, 0, 0), (0, 0, 0.30), (0, 1, 0))]

    # Rotor masts, fore and aft.
    top = zc + 0.95 * 0.7071
    hubs = []
    for y, rise in ((-1.55, 0.60), (2.25, 1.00)):
        mast = common.drop_bottom(common.block(f"mast_{y:+.2f}", 0.60, 0.70, rise + 0.05, top=(0.34, 0.40), origin=(0.0, y, top - 0.10)))
        trims.append(mast)
        hubs.append((0.0, y, top - 0.05 + rise))

    for obj in trims:
        common.trim_mat(obj)
    for obj in glows:
        common.glow_mat(obj, palette.JET_EXHAUST)
    objects += trims + glows

    rotor(objects, "rotor_front", hubs[0], 2.30, 0.36, 9.0, 90.0, accent)
    rotor(objects, "rotor_back", hubs[1], 2.30, 0.36, -9.0, 30.0, accent)

    return objects
