"""unit_defs/vehicle_t1.luau `pounder` (corlevlr): Cortex's riot tank, a stubby cannon with a big, flat blast.

Wider and lower than the
Brute, in under 100 triangles: a flat, wide gunmetal hull on broad dark tracks, heavy team-coloured side armour
sloping in over them, a low, wide turret set well forward, and one short, fat barrel ending in a squat muzzle box,
so it reads as heavy and short-ranged next to the Brute's longer gun.
"""

from .shared import common
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "pounder"
MOUNTS = {
    1: {"pivot": (0, 1.1368, 0.0766), "muzzle": (0.256, 0.5856, 1.378)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent)
    objects = []

    # Hull (the footprint object): 18, a blunt, steep nose and a short sloped rear.
    hull = v.prism(
        "hull",
        [(-1.12, 0.22), (-0.9, 0.62), (0.92, 0.64), (1.12, 0.42), (1.1, 0.18), (-1.0, 0.18)],
        width_bottom=1.3,
        width_top=1.18,
    )
    common.body_mat(hull)
    objects.append(hull)

    # Broad tracks, their lower run only, without floor or inner face: 8 each.
    tracks = [
        common.block(f"track_{side}", 0.44, 1.8, 0.46, top=(0.44, 2.0), origin=(side * 0.8, 0.0, 0.0), drop=("bottom", "left" if side > 0 else "right"))
        for side in (-1.0, 1.0)
    ]
    m.paint("trim", *tracks)
    objects.append(common.merge("tracks", tracks))

    # Side armour sloping in over the tracks: 10 each.
    skirts = [
        v.prism(
            f"skirt_{side}",
            [(-1.0, 0.4), (-0.82, 0.7), (0.86, 0.7), (1.0, 0.4)],
            width_bottom=0.5,
            width_top=0.3,
            origin=(side * 0.78, 0.0, 0.0),
        )
        for side in (-1.0, 1.0)
    ]
    m.paint("accent", *skirts)
    objects.append(common.merge("skirts", skirts))

    # A low, wide turret about its ring, set forward: 14.
    pivot = (0.0, -0.06, 0.66)
    turret = v.prism(
        "turret",
        [(-0.58, 0.0), (-0.36, 0.3), (0.42, 0.32), (0.62, 0.16), (0.62, 0.0)],
        width_bottom=1.2,
        width_top=0.86,
        origin=pivot,
    )
    common.accent_mat(turret, accent)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # One short, fat barrel (10) and a squat muzzle box (10), in dark metal, and a hatch on the turret roof (10).
    bz = 0.16
    barrel, tip = v.beam("barrel", 0.28, 0.28, 0.5, (0.0, -0.4, bz))
    muzzle, _ = v.beam("muzzle", 0.4, 0.36, 0.2, (0.0, tip[1] + 0.02, bz))
    hatch = common.block("hatch", 0.34, 0.3, 0.08, top=(0.26, 0.22), origin=(-0.2, 0.18, 0.3), drop=('bottom',))
    gun = [barrel, muzzle, hatch]
    m.paint("trim", *gun)
    gun = common.merge("gun", gun, origin=pivot)
    objects.append(common.art_group(gun, "turret_1"))

    return objects
