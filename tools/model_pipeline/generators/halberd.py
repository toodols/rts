"""unit_defs/hover_t1.luau `halberd` (BAR corhal): Cortex's heavy assault hovercraft, the tank of the hover line.

A broad, flat slab of
armour in under 100 triangles: a dark rubber skirt flaring out round the bottom, a wide angular hull with a
sloped glacis, thick team-coloured armour plates bolted along both flanks, and a wide rectangular fan duct across
the stern with two static fans in it. On top, set slightly forward, a big wedge-shaped armoured turret carrying one
thick laser barrel with a green lens at its tip (weapon 1), so it reads as heavier than any other hover.
"""

from .shared import common
from .shared import palette
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "halberd"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"length": 4.94, "height": 1.22}
MOUNTS = {
    1: {"pivot": (0, 0.72, 0.08), "muzzle": (0, 0.27, 2.39)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent)
    objects = []

    # Hull (the footprint object): wide angular slab with a glacis nose and a sloped stern. 14 triangles.
    deck_z = 0.72
    hull = v.prism(
        "hull",
        [(-1.62, 0.28), (-1.08, deck_z), (1.22, deck_z), (1.58, 0.5), (1.58, 0.28)],
        width_bottom=2.9,
        width_top=2.46,
    )
    common.body_mat(hull)
    objects.append(hull)

    # Skirt: a dark apron flaring out round the bottom, wider than the hull, no floor. 10 triangles.
    skirt = common.block("skirt", 3.4, 3.62, 0.32, top=(3.0, 3.3), drop=('bottom',))
    common.trim_mat(skirt)
    objects.append(skirt)

    # Heavy armour plates along both flanks, sloping in, team-coloured. 10 each.
    plates = [
        common.block(f"plate_{side}", 0.42, 2.5, 0.3, top=(0.26, 2.3), top_offset=(side * 0.06, 0.05), origin=(side * 1.26, 0.1, 0.42), drop=('bottom',))
        for side in (-1.0, 1.0)
    ]
    m.paint("accent", *plates)
    objects.append(common.merge("plates", plates))

    # Stern fan duct: a wide box open front and back (top and side walls, 6), a centre divider (4) and two static
    # fan faces set inside it (2 each).
    duct_y, duct_d, duct_w, duct_h = 1.72, 0.34, 2.2, 0.62
    duct = common.block("duct", duct_w, duct_d, duct_h, origin=(0.0, duct_y, 0.3), drop=("bottom", "front", "back"))
    divider = common.block("divider", 0.1, duct_d, duct_h, origin=(0.0, duct_y, 0.3), drop=("bottom", "front", "back",
                                                                                          "top"))
    duct_parts = [duct, divider]
    m.paint("body", *duct_parts)
    objects.append(common.merge("duct_m", duct_parts))

    fans = []
    for side in (-1.0, 1.0):
        fan = common.mesh(
            f"fan_{side}",
            [(-0.46, 0.0, 0.04), (0.46, 0.0, 0.04), (0.46, 0.0, 0.58), (-0.46, 0.0, 0.58)],
            [[0, 1, 2, 3]],
            (side * 0.55, duct_y + 0.02, 0.3),
        )
        fans.append(fan)
    m.paint("trim", *fans)
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
    common.accent_mat(turret, accent)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # A boxy mantlet on the turret face (8) and one thick laser barrel buried in it (10).
    mantlet = common.block("mantlet", 0.5, 0.3, 0.34, top=(0.42, 0.24), origin=(0.0, -0.68, 0.1), drop=("bottom", "back"))
    barrel, tip = v.beam("barrel", 0.28, 0.28, 1.4, (0.0, -0.7, 0.27), top_scale=0.7)
    gun = [mantlet, barrel]
    m.paint("trim", *gun)
    barrel = common.merge("barrel_m", gun, origin=pivot)
    objects.append(common.art_group(barrel, "turret_1"))

    # Green lens at the muzzle. 8.
    lens = v.diamond("lens", 0.14, (pivot[0], pivot[1] + tip[1] - 0.1, pivot[2] + tip[2]), length=0.38)
    common.glow_mat(lens, palette.LASER_GREEN)
    objects.append(common.art_group(lens, "turret_1"))

    return objects
