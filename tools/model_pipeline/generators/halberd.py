"""unit_defs/hover_t1.luau `halberd` (BAR corhal): Cortex's heavy assault hovercraft, the tank of the hover line.

Collider capsule(42, 12, 42): radius 1.91, height 1.09 studs -- wide, square and very low. A broad, flat slab of
armour in under 100 triangles: a dark rubber skirt flaring out round the bottom, a wide angular hull with a
sloped glacis, thick team-coloured armour plates bolted along both flanks, and a wide rectangular fan duct across
the stern with two static fans in it. On top, set slightly forward, a big wedge-shaped armoured turret carrying one
thick laser barrel with a green lens at its tip (weapon 1), so it reads as heavier than any other hover.
"""

from . import common
from . import vehicle_t1_common as v

NAME = "halberd"
ACCENT = v.rgb(120, 150, 196)
LASER_GREEN = (0.2, 1.0, 0.25, 1.0)


def generate(params):
    accent = tuple(params.get("accent_color", ACCENT))
    objects = []

    # Hull (the footprint object): wide angular slab with a glacis nose and a sloped stern. 14 triangles.
    deck_z = 0.72
    hull = v.prism(
        "hull",
        [(-1.62, 0.28), (-1.08, deck_z), (1.22, deck_z), (1.58, 0.5), (1.58, 0.28)],
        width_bottom=2.9,
        width_top=2.46,
    )
    v.body_mat(hull)
    objects.append(hull)

    # Skirt: a dark apron flaring out round the bottom, wider than the hull, no floor. 10 triangles.
    skirt = v.block("skirt", 3.4, 3.62, 0.32, top_x=3.0, top_y=3.3)
    v.dark_mat(skirt)
    objects.append(skirt)

    # Heavy armour plates along both flanks, sloping in, team-coloured. 10 each.
    plates = [
        v.block(f"plate_{side}", 0.42, 2.5, 0.3, top_x=0.26, top_y=2.3, top_offset=(side * 0.06, 0.05),
                origin=(side * 1.26, 0.1, 0.42))
        for side in (-1.0, 1.0)
    ]
    v.paint(plates, v.accent_mat, NAME, accent)
    objects.append(common.merge("plates", plates))

    # Stern fan duct: a wide box open front and back (top and side walls, 6), a centre divider (4) and two static
    # fan faces set inside it (2 each).
    duct_y, duct_d, duct_w, duct_h = 1.72, 0.34, 2.2, 0.62
    duct = v.block("duct", duct_w, duct_d, duct_h, origin=(0.0, duct_y, 0.3), skip=("bottom", "front", "back"))
    divider = v.block("divider", 0.1, duct_d, duct_h, origin=(0.0, duct_y, 0.3), skip=("bottom", "front", "back",
                                                                                          "top"))
    duct_parts = [duct, divider]
    v.paint(duct_parts, v.body_mat)
    objects.append(common.merge("duct_m", duct_parts))

    fans = []
    for side in (-1.0, 1.0):
        fan = v._object(
            f"fan_{side}",
            [(-0.46, 0.0, 0.04), (0.46, 0.0, 0.04), (0.46, 0.0, 0.58), (-0.46, 0.0, 0.58)],
            [[0, 1, 2, 3]],
            (side * 0.55, duct_y + 0.02, 0.3),
        )
        fans.append(fan)
    v.paint(fans, v.dark_mat)
    objects.append(common.merge("fans", fans))

    # Big armoured wedge turret on its ring, set a little forward. 16 triangles.
    pivot = (0.0, -0.1, deck_z)
    turret = v.prism(
        "turret",
        [(-0.82, 0.0), (-0.52, 0.46), (0.5, 0.5), (0.8, 0.26), (0.8, 0.0)],
        width_bottom=1.72,
        width_top=1.14,
        origin=pivot,
    )
    v.accent_mat(turret, NAME, accent)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # A boxy mantlet on the turret face (8) and one thick laser barrel buried in it (10).
    mantlet = v.block("mantlet", 0.5, 0.3, 0.34, top_x=0.42, top_y=0.24, origin=(0.0, -0.68, 0.1),
                      skip=("bottom", "back"))
    barrel, tip = v.beam("barrel", 0.28, 0.28, 1.4, (0.0, -0.7, 0.27), top_scale=0.7)
    gun = [mantlet, barrel]
    v.paint(gun, v.dark_mat)
    barrel = common.merge("barrel_m", gun, origin=pivot)
    objects.append(common.art_group(barrel, "turret_1"))

    # Green lens at the muzzle. 8.
    lens = v.diamond("lens", 0.14, (pivot[0], pivot[1] + tip[1] - 0.1, pivot[2] + tip[2]), length=0.38)
    v.glow_mat(lens, NAME, LASER_GREEN)
    objects.append(common.art_group(lens, "turret_1"))

    return v.finish(objects)
