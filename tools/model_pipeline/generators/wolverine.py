"""unit_defs/vehicle_t1.luau `wolverine` (corwolv): Cortex's light artillery tank.

Collider capsule(28, 22, 38): radius 1.73 studs, height 2.0. A long, low tracked chassis with a tall wedge
casemate set at the back and one long barrel raised high over the nose, the silhouette that says "artillery"
from across the map, in under 100 triangles. A muzzle brake and an amber glow mark the barrel's tip.
"""

from . import common
from . import vehicle_t1_common as v

NAME = "wolverine"
ACCENT = v.rgb(196, 96, 80)
PITCH = 30.0  # barrel elevation, degrees


def generate(params):
    accent = tuple(params.get("accent_color", ACCENT))
    objects = []

    # Hull (the footprint object): 18.
    hull = v.prism(
        "hull",
        [(-1.42, 0.28), (-0.96, 0.62), (1.2, 0.64), (1.42, 0.42), (1.36, 0.16), (-1.24, 0.16)],
        width_bottom=0.92,
        width_top=0.86,
    )
    v.body_mat(hull)
    objects.append(hull)

    # Trapezoid track runs, outer caps only: 8 each.
    tracks = [
        v.prism(
            f"track_{side}",
            [(-1.12, 0.0), (1.12, 0.0), (1.4, 0.44), (-1.4, 0.44)],
            width_bottom=0.3,
            origin=(side * 0.6, 0.0, 0.0),
            caps="right" if side > 0 else "left",
        )
        for side in (-1.0, 1.0)
    ]
    v.paint(tracks, v.dark_mat)
    objects.append(common.merge("tracks", tracks))

    # Team-coloured fenders: 10 each.
    fenders = [
        v.block(f"fender_{side}", 0.36, 2.84, 0.07, top_y=2.64, top_offset=(0.0, 0.06), origin=(side * 0.6, 0.02, 0.44))
        for side in (-1.0, 1.0)
    ]
    v.paint(fenders, v.accent_mat, NAME, accent)
    objects.append(common.merge("fenders", fenders))

    # Tall wedge casemate at the back of the deck, about its ring: 10.
    pivot = (0.0, 0.5, 0.64)
    mount = v.prism(
        "mount",
        [(-0.52, 0.0), (-0.22, 0.5), (0.5, 0.54), (0.64, 0.0)],
        width_bottom=1.02,
        width_top=0.7,
        origin=pivot,
    )
    v.accent_mat(mount, NAME, accent)
    objects.append(common.art_group(mount, "turret_1", pivot=True, kind="turret", weapon=1))

    # Long raised barrel (10) and muzzle brake (10).
    barrel, tip = v.beam("barrel", 0.15, 0.15, 1.7, (0.0, -0.2, 0.3), pitch_deg=PITCH, top_scale=0.8)
    brake, brake_tip = v.beam("brake", 0.24, 0.2, 0.22, (0.0, tip[1] + 0.16 * 0.87, tip[2] - 0.16 * 0.5), pitch_deg=PITCH)
    gun = [barrel, brake]
    v.paint(gun, v.dark_mat)
    objects.append(common.art_group(common.merge("gun", gun, origin=pivot), "turret_1"))

    glow = v.diamond("muzzle_glow", 0.08, (pivot[0], pivot[1] + brake_tip[1], pivot[2] + brake_tip[2]), length=0.16)
    v.glow_mat(glow, NAME)
    objects.append(common.art_group(glow, "turret_1"))

    return v.finish(objects)
