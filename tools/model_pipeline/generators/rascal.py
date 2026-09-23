"""unit_defs/vehicle_t1.luau `rascal` (corfav): Cortex's fast, fragile scout with a light laser.

Collider capsule(16, 16, 26): radius 1.18 studs, height 1.45. The only small wheeled thing in the tier, in under
100 triangles: a narrow team-coloured buggy wedge on four big, exposed, dark six-sided wheels, with a little
gunmetal laser mount on its back. Each wheel rolls on its own hub as it drives. The wheels are oversized on purpose so it reads as fast and light next to the
tracked tanks.
"""

from . import common
from . import vehicle_t1_common as v

NAME = "rascal"
ACCENT = v.rgb(196, 96, 80)


def generate(params):
    accent = tuple(params.get("accent_color", ACCENT))
    objects = []

    # Buggy body (the footprint object), team-coloured: a low nose rising to the cockpit, a short rear deck: 14.
    body = v.prism(
        "body",
        [(-0.98, 0.2), (-0.36, 0.44), (0.62, 0.44), (0.9, 0.12), (-0.86, 0.12)],
        width_bottom=0.6,
        width_top=0.44,
    )
    v.accent_mat(body, NAME, accent)
    objects.append(body)

    # Four big wheels, each its own rolling piece about its hub: 16 each.
    objects += v.rolling_wheels("wheel", 0.3, 0.22, 0.52, (-0.64, 0.64), v.dark_mat)

    # Little laser mount on the back deck, a squat pyramid leaning back: 4.
    pivot = (0.0, 0.32, 0.44)
    turret = v.pyramid_up("turret", 0.4, 0.46, 0.24, apex=(0.0, 0.1), origin=pivot)
    v.body_mat(turret)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # Barrel (10) with a red lens spike at the tip (4).
    barrel, tip = v.beam("barrel", 0.08, 0.08, 0.72, (0.0, -0.06, 0.12))
    v.dark_mat(barrel)
    objects.append(common.art_group(common.merge("barrel_m", [barrel], origin=pivot), "turret_1"))
    lens = v.spike("lens", 0.07, 0.16, (pivot[0], pivot[1] + tip[1] + 0.02, pivot[2] + tip[2]))
    v.glow_mat(lens, NAME, v.LASER_COLOR)
    objects.append(common.art_group(lens, "turret_1"))

    return v.finish(objects)
