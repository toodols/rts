"""unit_defs `wind_turbine` (corwin): 1x2x1 cells (4 wide, 8 tall, 4 long), grey-steel accent. Budget: 100
triangles.

A tall, spare Cortex turbine: a sloped hexagonal plinth braced by three dark fins, a tapering gunmetal mast
whose upper half is in the accent colour, and on top an armored accent nacelle with a dark tail fin and a
warning light, carrying a three-bladed rotor on its front (Blender -Y). The rotor -- spinner and blades -- is
its own rigid piece pivoting on the hub centre, spinning about the horizontal hub axis (common.art_group,
kind="spin", axis Blender Y). Its blades poke a little above the collider, like the advanced construction
turret's mast.
"""

import math

from . import common
from . import economy_common as eco


def generate(params):
    w = float(params.get("width", 4.0))
    height = float(params.get("height", 8.0))
    s = w / 4.0
    objects = []

    plinth_h = 0.65 * s
    plinth = eco.Mesh().frustum(eco.ngon(2.15 * s, 6), eco.ngon(1.45 * s, 6), 0.0, plinth_h)
    objects.append(eco.body(plinth.build("plinth")))

    hub_z = height * 0.76
    mast_top = hub_z - 0.35 * s
    mid = plinth_h + (mast_top - plinth_h) * 0.5

    def mast_r(z):
        f = (z - plinth_h) / (mast_top - plinth_h)
        return (0.5 + (0.3 - 0.5) * f) * s

    lower = eco.Mesh().frustum(eco.rect(2 * mast_r(plinth_h), 2 * mast_r(plinth_h)), eco.rect(2 * mast_r(mid), 2 * mast_r(mid)), plinth_h, mid, cap_top=False)
    objects.append(eco.body(lower.build("mast")))

    acc = eco.Mesh()
    acc.frustum(eco.rect(2 * mast_r(mid), 2 * mast_r(mid)), eco.rect(2 * mast_r(mast_top), 2 * mast_r(mast_top)), mid, mast_top + 0.1 * s, cap_top=False)
    # Nacelle along Y, a little behind the mast so the rotor clears it.
    nz = mast_top
    nac_b = eco.rect(0.95 * s, 2.1 * s, (0.0, 0.1 * s))
    nac_t = eco.rect(0.7 * s, 1.7 * s, (0.0, 0.2 * s))
    acc.frustum(nac_b, nac_t, nz, nz + 0.8 * s, cap_bottom=True)
    objects.append(eco.accent(acc.build("nacelle"), "wind", eco.WIND))

    dark = eco.Mesh()
    for i in range(3):
        eco.wedge(dark, math.radians(90.0 + 120.0 * i), 0.3 * s, 1.75 * s, 0.26 * s, plinth_h - 0.05 * s, 1.9 * s)
    # tail fin: a thin plate standing up off the nacelle's back, both faces
    fin = [(0.0, 0.9 * s, nz + 0.5 * s), (0.0, 1.9 * s, nz + 0.7 * s), (0.0, 1.9 * s, nz + 1.5 * s), (0.0, 1.1 * s, nz + 0.8 * s)]
    dark.poly(fin)
    dark.poly([(0.04 * s, y, z) for _, y, z in reversed(fin)])
    objects.append(eco.trim(dark.build("fins")))

    light = eco.Mesh().pyramid(eco.at(eco.ngon(0.14 * s, 4), nz + 0.8 * s), (0.0, 0.5 * s, nz + 1.05 * s))
    objects.append(eco.glow(light.build("warning_light"), "wind", (1.0, 0.25, 0.15, 1.0), emission=1.0))

    # The rotor, pivoting on the hub centre in front of the nacelle.
    hub_y = -1.2 * s
    rotor = eco.Mesh()
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
        rotor.poly(front, m=m)
        rotor.poly(back, m=m)
    blades = rotor.build("rotor", location=(0.0, hub_y, hub_z))
    # pale painted blades, so the rotor reads against the gunmetal and the team-coloured nacelle
    common.apply_material(blades, "eco_wind_blade", (0.75, 0.76, 0.78, 1.0), roughness=0.45, metallic=0.3)
    objects.append(common.art_group(blades, "rotor", pivot=True, kind="spin", axis=(0.0, 1.0, 0.0), speed=2.4))

    return objects
