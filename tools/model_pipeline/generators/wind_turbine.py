"""unit_defs `wind_turbine` (corwin): grey-steel accent. Budget: 100
triangles.

A tall, spare Cortex turbine: a sloped hexagonal plinth braced by three dark fins, a tapering gunmetal mast
whose upper half is in the accent colour, and on top an armored accent nacelle with a dark tail fin and a
warning light, carrying a three-bladed rotor on its front (Blender -Y). The rotor -- spinner and blades -- is
its own rigid piece pivoting on the hub centre, spinning about the horizontal hub axis (common.art_group,
kind="spin", axis Blender Y). Its blades poke a little above the collider, like the advanced construction
turret's mast.
"""

import math

from .shared import common
from .shared import economy as eco
from .shared import palette

CATEGORY = "entity"
DEF = "wind_turbine"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"width": 4.3, "height": 8.58}


def generate(params):
    accent = params["color"]
    w = params["collider"]["width"]
    height = params["collider"]["height"]
    s = w / 4.0
    objects = []

    plinth_h = 0.65 * s
    plinth = common.Faces().frustum(common.ngon(6, 2.15 * s), common.ngon(6, 1.45 * s), 0.0, plinth_h)
    objects.append(common.body_mat(plinth.build("plinth")))

    hub_z = height * 0.76
    mast_top = hub_z - 0.35 * s
    mid = plinth_h + (mast_top - plinth_h) * 0.5

    def mast_r(z):
        f = (z - plinth_h) / (mast_top - plinth_h)
        return (0.5 + (0.3 - 0.5) * f) * s

    lower = common.Faces().frustum(common.rect(2 * mast_r(plinth_h), 2 * mast_r(plinth_h)), common.rect(2 * mast_r(mid), 2 * mast_r(mid)), plinth_h, mid, cap_top=False)
    objects.append(common.body_mat(lower.build("mast")))

    acc = common.Faces()
    acc.frustum(common.rect(2 * mast_r(mid), 2 * mast_r(mid)), common.rect(2 * mast_r(mast_top), 2 * mast_r(mast_top)), mid, mast_top + 0.1 * s, cap_top=False)
    # Nacelle along Y, a little behind the mast so the rotor clears it.
    nz = mast_top
    nac_b = common.rect(0.95 * s, 2.1 * s, (0.0, 0.1 * s))
    nac_t = common.rect(0.7 * s, 1.7 * s, (0.0, 0.2 * s))
    acc.frustum(nac_b, nac_t, nz, nz + 0.8 * s, cap_bottom=True)
    objects.append(common.accent_mat(acc.build("nacelle"), accent))

    dark = common.Faces()
    for i in range(3):
        eco.wedge(dark, math.radians(90.0 + 120.0 * i), 0.3 * s, 1.75 * s, 0.26 * s, plinth_h - 0.05 * s, 1.9 * s)
    # tail fin: a thin plate standing up off the nacelle's back, both faces
    fin = [(0.0, 0.9 * s, nz + 0.5 * s), (0.0, 1.9 * s, nz + 0.7 * s), (0.0, 1.9 * s, nz + 1.5 * s), (0.0, 1.1 * s, nz + 0.8 * s)]
    dark.polygon(fin)
    dark.polygon([(0.04 * s, y, z) for _, y, z in reversed(fin)])
    objects.append(common.trim_mat(dark.build("fins")))

    light = common.Faces().pyramid(common.at(common.ngon(4, 0.14 * s), nz + 0.8 * s), (0.0, 0.5 * s, nz + 1.05 * s))
    objects.append(common.glow_mat(light.build("warning_light"), palette.BEACON_RED))

    # The rotor, pivoting on the hub centre in front of the nacelle.
    hub_y = -1.2 * s
    rotor = common.Faces()
    # spinner: a hexagonal cone pointing forward (-Y); its back is against the nacelle
    ring = [(0.42 * s * math.cos(t), hub_y + 0.2 * s, hub_z + 0.42 * s * math.sin(t)) for t in (2 * math.pi * k / 6 for k in range(6))]
    rotor.pyramid(ring, (0.0, hub_y - 0.65 * s, hub_z))
    span, chord = 2.5 * s, 0.85 * s
    plan = [(-chord * 0.3, 0.25 * s), (chord * 0.35, 0.25 * s), (chord * 0.62, span * 0.35), (chord * 0.25, span), (-chord * 0.12, span), (-chord * 0.4, span * 0.35)]
    pitch = math.radians(14.0)
    for i in range(3):
        m = eco.matrix((0.0, hub_y, hub_z), (0.0, math.radians(120.0 * i), 0.0)) @ eco.matrix(rotation=(0.0, 0.0, pitch))
        # the blade lies in the local XZ plane, span up +Z; front face toward -Y, back face 0.07 behind
        front = [(x, 0.0, z) for x, z in plan]
        back = [(x, 0.07 * s, z) for x, z in reversed(plan)]
        rotor.polygon(front, matrix=m)
        rotor.polygon(back, matrix=m)
    blades = rotor.build_about("rotor", (0.0, hub_y, hub_z))
    # pale painted blades, so the rotor reads against the gunmetal and the team-coloured nacelle
    common.paint(blades, palette.WIND_BLADE)
    objects.append(common.art_group(blades, "rotor", pivot=True, kind="spin", axis=(0.0, 1.0, 0.0), speed=2.4))

    return objects
