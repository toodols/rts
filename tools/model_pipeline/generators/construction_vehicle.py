"""unit_defs/vehicle_t1.luau `construction_vehicle` (corcv): Cortex's tracked builder.

The biggest of the tier and a worker, not a
fighter, in under 100 triangles: a long boxy tracked hull with a team-coloured cab up front and, on a turntable
behind it, a high-vis yellow nanolathe crane arm that reaches up and over the cab to a glowing green emitter,
like the construction turret's. The turntable, arm and emitter turn together toward whatever it is building.
"""

from .shared import common
from .shared import palette
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "construction_vehicle"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 4.48}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent)
    objects = []

    # Hull (the footprint object): 18, and a rear engine block: 10.
    hull = v.prism(
        "hull",
        [(-1.8, 0.36), (-1.42, 0.8), (1.5, 0.84), (1.78, 0.6), (1.7, 0.2), (-1.6, 0.2)],
        width_bottom=1.2,
        width_top=1.1,
    )
    engine = common.block("engine", 0.9, 0.56, 0.22, top=(0.8, 0.44), origin=(0.0, 1.18, 0.83), drop=('bottom',))
    m.paint("body", *[hull, engine])
    objects += [hull, engine]

    # Wide trapezoid tracks, outer caps only: 8 each.
    tracks = [
        v.prism(
            f"track_{side}",
            [(-1.5, 0.0), (1.5, 0.0), (1.82, 0.56), (-1.82, 0.56)],
            width_bottom=0.42,
            origin=(side * 0.8, 0.0, 0.0),
            caps="right" if side > 0 else "left",
        )
        for side in (-1.0, 1.0)
    ]
    m.paint("trim", *tracks)
    objects.append(common.merge("tracks", tracks))

    # Team-coloured cab at the front: 10.
    cab = common.block("cab", 1.16, 0.74, 0.42, top=(0.96, 0.4), top_offset=(0.0, 0.1), origin=(0.0, -1.02, 0.8), drop=('bottom',))
    common.accent_mat(cab, accent)
    objects.append(cab)

    # Nanolathe crane on a turntable behind the cab.
    pivot = (0.0, 0.5, 0.84)
    table = common.block("turntable", 0.9, 0.9, 0.22, top=(0.7, 0.74), top_offset=(0.0, 0.06), origin=pivot, drop=('bottom',))
    common.accent_mat(table, accent)
    objects.append(common.art_group(table, "work", pivot=True, kind="work"))

    boom, elbow = v.beam("boom", 0.3, 0.3, 1.5, (0.0, 0.24, 0.16), pitch_deg=50.0, drop=("back", "bottom"), top_scale=0.8)
    fore, wrist = v.beam("forearm", 0.24, 0.24, 0.92, (0.0, elbow[1] + 0.08, elbow[2] - 0.08), pitch_deg=-34.0, drop=("back",), top_scale=0.8)
    arm = [boom, fore]
    m.paint("hivis", *arm)
    objects.append(common.art_group(common.merge("arm", arm, origin=pivot), "work"))

    emitter = v.diamond("emitter", 0.18, (pivot[0], pivot[1] + wrist[1] - 0.04, pivot[2] + wrist[2] - 0.02))
    common.glow_mat(emitter, palette.NANO)
    objects.append(common.art_group(emitter, "work"))

    return objects
