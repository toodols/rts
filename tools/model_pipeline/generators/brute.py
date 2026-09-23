"""unit_defs/vehicle_t1.luau `brute` (corraid): Cortex's medium assault tank with a light plasma cannon.

Collider capsule(32, 24, 32): radius 1.45 studs, height 2.18, a square footprint. Where the Incisor is a low
wedge, the Brute is a slab (under 100 triangles): wide dark tracks under heavy sloped side skirts in team colour,
a broad armoured turret filling most of the roof, and a short, thick cannon with a boxy muzzle brake.
"""

from . import common
from . import vehicle_t1_common as v

NAME = "brute"
ACCENT = v.rgb(176, 122, 88)


def generate(params):
    accent = tuple(params.get("accent_color", ACCENT))
    objects = []

    # Hull (the footprint object): 18.
    hull = v.prism(
        "hull",
        [(-1.02, 0.26), (-0.66, 0.74), (0.78, 0.78), (1.0, 0.56), (0.98, 0.2), (-0.86, 0.2)],
        width_bottom=1.08,
        width_top=1.0,
    )
    v.body_mat(hull)
    objects.append(hull)

    # Tracks: only their lower run shows under the skirts, so each is a trapezoid block without floor or inner
    # face: 8 each.
    tracks = [
        v.block(
            f"track_{side}", 0.38, 1.66, 0.44, top_y=1.9, origin=(side * 0.7, 0.0, 0.0),
            skip=("bottom", "left" if side > 0 else "right"),
        )
        for side in (-1.0, 1.0)
    ]
    v.paint(tracks, v.dark_mat)
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
    v.paint(skirts, v.accent_mat, NAME, accent)
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
    v.accent_mat(turret, NAME, accent)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # Thick short cannon (10), muzzle brake (10) and commander's cupola (10), in dark metal.
    bz = 0.2
    barrel, tip = v.beam("barrel", 0.18, 0.18, 0.78, (0.0, -0.44, bz))
    brake, _ = v.beam("brake", 0.3, 0.24, 0.22, (0.0, tip[1] + 0.2, bz))
    cupola = v.block("cupola", 0.3, 0.3, 0.1, top_x=0.22, top_y=0.22, origin=(0.22, 0.24, 0.37))
    gun = [barrel, brake, cupola]
    v.paint(gun, v.dark_mat)
    gun = common.merge("gun", gun, origin=pivot)
    objects.append(common.art_group(gun, "turret_1"))

    return v.finish(objects)
