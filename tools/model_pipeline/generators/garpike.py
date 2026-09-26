"""unit_defs/vehicle_t1.luau `garpike` (corgarp): Cortex's light amphibious tank, which drives along the sea floor.

Under 100 triangles. Where the Brute is a slab, the Garpike is a low boat on tracks: a hull with a long raked prow for
pushing through water, tracks under narrow sponsons in team colour, and a small low turret set well back with a long,
thin gauss cannon.
"""

from .shared import common
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "garpike"
MOUNTS = {
    1: {"pivot": (0, 1.0876, -0.4406), "muzzle": (-0.085, 0.1359, 2.014)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent)
    objects = []

    # Hull (the footprint object): a low boat's profile, the prow (-Y, the front) raked far forward: 18.
    hull = v.prism(
        "hull",
        [(-1.1, 0.2), (-0.5, 0.6), (0.86, 0.62), (1.0, 0.4), (0.96, 0.18), (-0.9, 0.18)],
        width_bottom=0.96,
        width_top=0.82,
    )
    common.body_mat(hull)
    objects.append(hull)

    # Tracks: their lower run under the sponsons, without floor or inner face: 8 each.
    tracks = [
        common.block(f"track_{side}", 0.3, 1.6, 0.36, top=(0.3, 1.8), origin=(side * 0.6, 0.0, 0.0), drop=("bottom", "left" if side > 0 else "right"))
        for side in (-1.0, 1.0)
    ]
    m.paint("trim", *tracks)
    objects.append(common.merge("tracks", tracks))

    # Sponsons: narrow sloped floats over the tracks, in team colour: 10 each.
    sponsons = [
        v.prism(
            f"sponson_{side}",
            [(-0.96, 0.3), (-0.8, 0.54), (0.7, 0.54), (0.94, 0.3)],
            width_bottom=0.36,
            width_top=0.22,
            origin=(side * 0.6, 0.0, 0.0),
        )
        for side in (-1.0, 1.0)
    ]
    m.paint("accent", *sponsons)
    objects.append(common.merge("sponsons", sponsons))

    # A small low turret set back on the hull, about its ring: 14.
    pivot = (0.0, 0.3, 0.64)
    turret = v.prism(
        "turret",
        [(-0.42, 0.0), (-0.24, 0.24), (0.3, 0.26), (0.46, 0.12), (0.46, 0.0)],
        width_bottom=0.72,
        width_top=0.5,
        origin=pivot,
    )
    common.accent_mat(turret, accent)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # The long thin gauss cannon (10) and a coil band round it (10), in dark metal.
    bz = 0.13
    barrel, tip = v.beam("barrel", 0.1, 0.1, 1.2, (0.0, -0.4, bz))
    coil, _ = v.beam("coil", 0.18, 0.18, 0.16, (0.0, -0.6, bz))
    gun = [barrel, coil]
    m.paint("trim", *gun)
    gun = common.merge("gun", gun, origin=pivot)
    objects.append(common.art_group(gun, "turret_1"))

    return objects
