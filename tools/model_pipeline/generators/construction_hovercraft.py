"""unit_defs/hover_t1.luau `construction_hovercraft` (corch): Cortex's builder hovercraft.

A low, chunky gunmetal hull with a sloped glacis
riding on a dark rubber skirt that flares out past it, a team-coloured cab up front and, at the back, a dark duct
housing holding two ringed lift fans facing aft. On a turntable amidships, a high-vis yellow nanolathe crane arm
reaches up and over the cab to a glowing green emitter, like the construction vehicle's; the turntable, arm and
emitter turn together toward whatever it is building. 100 triangles, nothing bevelled.
"""

import math

from .shared import common
from .shared import palette
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "construction_hovercraft"


def fan_ring(name, radius, inner, center, segments=6):
    """A flat hexagonal ring facing aft (+Y) round `center`: a fan duct's lip. 2 * segments triangles."""
    cx, cy, cz = center
    verts = []
    for r in (radius, inner):
        for i in range(segments):
            a = 2.0 * math.pi * i / segments + math.pi / 2.0
            verts.append((cx + r * math.cos(a), cy, cz + r * math.sin(a)))
    faces = []
    for i in range(segments):
        j = (i + 1) % segments
        # counter-clockwise seen from +Y, so the face shows aft
        faces.append((i, segments + i, segments + j, j))
    return common.mesh(name, verts, faces)


def generate(params):
    accent = params["color"]
    m = common.Materials(accent)
    objects = []

    # Rubber skirt (the footprint object), an apron bulging out to a lip round a narrower hull: 10.
    skirt = common.block("skirt", 1.8, 3.0, 0.34, top=(1.94, 3.14), drop=('bottom',))
    common.trim_mat(skirt)
    objects.append(skirt)

    # Hull on the skirt, sloped glacis forward and a short rear slope: 10.
    hull = v.prism(
        "hull",
        [(-1.36, 0.34), (-0.9, 0.76), (1.22, 0.8), (1.36, 0.34)],
        width_bottom=1.6,
        width_top=1.42,
    )
    common.body_mat(hull)
    objects.append(hull)

    # Team-coloured cab up front: 10.
    cab = common.block("cab", 0.92, 0.56, 0.3, top=(0.74, 0.34), top_offset=(0.0, 0.08), origin=(0.0, -0.6, 0.74), drop=('bottom',))
    common.accent_mat(cab, accent)
    objects.append(cab)

    # Fan duct housing at the stern, sunk into the hull: 10, with two fan rings on its back face: 12 each.
    duct = common.block("duct", 1.56, 0.42, 0.82, top=(1.5, 0.36), top_offset=(0.0, 0.03), origin=(0.0, 1.1, 0.5), drop=('bottom',))
    common.trim_mat(duct)
    objects.append(duct)
    rings = [fan_ring(f"fan_{s}", 0.35, 0.25, (s * 0.38, 1.315, 0.92)) for s in (-1.0, 1.0)]
    m.paint("body", *rings)
    objects.append(common.merge("fans", rings))

    # Nanolathe crane on a turntable amidships.
    pivot = (0.0, 0.22, 0.77)
    table = common.block("turntable", 0.7, 0.7, 0.18, top=(0.54, 0.58), top_offset=(0.0, 0.04), origin=pivot, drop=('bottom',))
    common.accent_mat(table, accent)
    objects.append(common.art_group(table, "work", pivot=True, kind="work"))

    boom, elbow = v.beam("boom", 0.26, 0.26, 1.3, (0.0, 0.18, 0.12), pitch_deg=58.0, drop=("back", "bottom"), top_scale=0.8)
    fore, wrist = v.beam("forearm", 0.2, 0.2, 0.72, (0.0, elbow[1] + 0.06, elbow[2] - 0.06), pitch_deg=-24.0, drop=("back",), top_scale=0.8)
    arm = [boom, fore]
    m.paint("hivis", *arm)
    objects.append(common.art_group(common.merge("arm", arm, origin=pivot), "work"))

    emitter = v.diamond("emitter", 0.15, (pivot[0], pivot[1] + wrist[1] - 0.03, pivot[2] + wrist[2] - 0.02))
    common.glow_mat(emitter, palette.NANO)
    objects.append(common.art_group(emitter, "work"))

    return objects
