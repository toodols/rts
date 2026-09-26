"""unit_defs/vehicle_t1.luau `brute` (corraid): Cortex's medium assault tank with a light plasma cannon.

Where the Incisor is a low
wedge, the Brute is a slab (under 100 triangles): wide dark tracks under heavy sloped side skirts in team colour,
a broad armoured turret filling most of the roof, and a short, thick cannon with a boxy muzzle brake.
"""

from .shared import common
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "brute"
MOUNTS = {
    1: {"pivot": (0, 1.3548, -0.1983), "muzzle": (-0.2297, 0.1408, 1.6397)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent)
    objects = []

    # Hull (the footprint object): 18.
    hull = v.prism(
        "hull",
        [(-1.02, 0.26), (-0.66, 0.74), (0.78, 0.78), (1.0, 0.56), (0.98, 0.2), (-0.86, 0.2)],
        width_bottom=1.08,
        width_top=1.0,
    )
    common.body_mat(hull)
    objects.append(hull)

    # Tracks: only their lower run shows under the skirts, so each is a trapezoid block without floor or inner
    # face: 8 each.
    tracks = [
        common.block(f"track_{side}", 0.38, 1.66, 0.44, top=(0.38, 1.9), origin=(side * 0.7, 0.0, 0.0), drop=("bottom", "left" if side > 0 else "right"))
        for side in (-1.0, 1.0)
    ]
    m.paint("trim", *tracks)
    objects.append(common.merge("tracks", tracks))

    # Side skirts: solid sloped armour sponsons over the upper track run: 10 each.
    skirts = [
        v.prism(
            f"skirt_{side}",
            [(-1.04, 0.36), (-0.82, 0.72), (0.9, 0.72), (1.02, 0.36)],
            width_bottom=0.5,
            width_top=0.3,
            origin=(side * 0.7, 0.0, 0.0),
        )
        for side in (-1.0, 1.0)
    ]
    m.paint("accent", *skirts)
    objects.append(common.merge("skirts", skirts))

    # Broad turret about its ring: 14.
    pivot = (0.0, 0.14, 0.77)
    turret = v.prism(
        "turret",
        [(-0.64, 0.0), (-0.34, 0.36), (0.46, 0.38), (0.68, 0.22), (0.68, 0.0)],
        width_bottom=1.26,
        width_top=0.8,
        origin=pivot,
    )
    common.accent_mat(turret, accent)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # Thick short cannon (10), muzzle brake (10) and commander's cupola (10), in dark metal.
    bz = 0.2
    barrel, tip = v.beam("barrel", 0.18, 0.18, 0.78, (0.0, -0.44, bz))
    brake, _ = v.beam("brake", 0.3, 0.24, 0.22, (0.0, tip[1] + 0.2, bz))
    cupola = common.block("cupola", 0.3, 0.3, 0.1, top=(0.22, 0.22), origin=(0.22, 0.24, 0.37), drop=('bottom',))
    gun = [barrel, brake, cupola]
    m.paint("trim", *gun)
    gun = common.merge("gun", gun, origin=pivot)
    objects.append(common.art_group(gun, "turret_1"))

    return objects
