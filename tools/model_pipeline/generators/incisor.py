"""unit_defs/vehicle_t1.luau `incisor` (corgator): Cortex's light laser tank.

A low, fast wedge in under 100 triangles: a narrow
hull with a steep glacis between two dark track runs, team-coloured fenders over the tracks, and a small wedge
turret set back on the roof carrying one long, thin laser barrel with a red lens at its tip, so it reads as quick
and sharp next to the squat Brute.
"""

from .shared import common
from .shared import palette
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "incisor"
MOUNTS = {
    1: {"pivot": (0, 1.0843, -0.2598), "muzzle": (0, 0.2711, 1.7362)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent)
    objects = []

    # Hull (the footprint object): 18 triangles.
    hull = v.prism(
        "hull",
        [(-1.22, 0.3), (-0.62, 0.64), (0.86, 0.68), (1.18, 0.5), (1.12, 0.16), (-1.0, 0.16)],
        width_bottom=0.9,
        width_top=0.8,
    )
    common.body_mat(hull)
    objects.append(hull)

    # Track runs with sloped ends, outer caps only: 14 each.
    tracks = []
    for side in (-1.0, 1.0):
        t = v.prism(
            f"track_{side}",
            [(-1.2, 0.24), (-0.98, 0.46), (1.0, 0.46), (1.18, 0.24), (0.98, 0.0), (-0.96, 0.0)],
            width_bottom=0.3,
            origin=(side * 0.6, 0.0, 0.0),
            caps="right" if side > 0 else "left",
        )
        tracks.append(t)
    m.paint("trim", *tracks)
    objects.append(common.merge("tracks", tracks))

    # Fenders, sloping down to the nose: 10 each.
    fenders = [
        common.block(f"fender_{side}", 0.36, 2.1, 0.07, top=(0.36, 1.9), top_offset=(0.0, 0.08), origin=(side * 0.6, 0.06, 0.46), drop=('bottom',))
        for side in (-1.0, 1.0)
    ]
    m.paint("accent", *fenders)
    objects.append(common.merge("fenders", fenders))

    # Wedge turret about its ring: 14.
    pivot = (0.0, 0.2, 0.68)
    turret = v.prism(
        "turret",
        [(-0.5, 0.0), (-0.26, 0.28), (0.36, 0.32), (0.52, 0.18), (0.52, 0.0)],
        width_bottom=0.82,
        width_top=0.52,
        origin=pivot,
    )
    common.accent_mat(turret, accent)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # Long thin laser barrel, its back buried in the turret: 10.
    barrel, tip = v.beam("barrel", 0.11, 0.11, 1.08, (0.0, -0.22, 0.17), top_scale=0.75)
    common.trim_mat(barrel)
    barrel = common.merge("barrel_m", [barrel], origin=pivot)
    objects.append(common.art_group(barrel, "turret_1"))

    lens = v.diamond("lens", 0.075, (pivot[0], pivot[1] + tip[1] - 0.06, pivot[2] + tip[2]), length=0.22)
    common.glow_mat(lens, palette.LASER_RED)
    objects.append(common.art_group(lens, "turret_1"))

    return objects
