"""unit_defs/vehicle_t1.luau `rascal` (corfav): Cortex's fast, fragile scout with a light laser.

The only small wheeled thing in the tier, in under
100 triangles: a narrow team-coloured buggy wedge on four big, exposed, dark six-sided wheels, with a little
gunmetal laser mount on its back. Each wheel rolls on its own hub as it drives. The wheels are oversized on purpose so it reads as fast and light next to the
tracked tanks.
"""

from .shared import common
from .shared import palette
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "rascal"
# its wheels are oversized on purpose, so that it reads as fast and light next to the tanks
ENVELOPE = {"length": 2.58}
MOUNTS = {
    1: {"pivot": (0, 0.6857, -0.4341), "muzzle": (0, 0.187, 1.1095)},
}


def generate(params):
    accent = params["color"]
    objects = []

    # Buggy body (the footprint object), team-coloured: a low nose rising to the cockpit, a short rear deck: 14.
    body = v.prism(
        "body",
        [(-0.98, 0.2), (-0.36, 0.44), (0.62, 0.44), (0.9, 0.12), (-0.86, 0.12)],
        width_bottom=0.6,
        width_top=0.44,
    )
    common.accent_mat(body, accent)
    objects.append(body)

    # Four big wheels, each its own rolling piece about its hub: 16 each.
    objects += v.rolling_wheels("wheel", 0.3, 0.22, 0.52, (-0.64, 0.64), common.trim_mat)

    # Little laser mount on the back deck, a squat pyramid leaning back: 4.
    pivot = (0.0, 0.32, 0.44)
    turret = common.pyramid("turret", 0.4, 0.46, 0.24, apex=(0.0, 0.1), origin=pivot, base=False)
    common.body_mat(turret)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # Barrel (10) with a red lens spike at the tip (4).
    barrel, tip = v.beam("barrel", 0.08, 0.08, 0.72, (0.0, -0.06, 0.12))
    common.trim_mat(barrel)
    objects.append(common.art_group(common.merge("barrel_m", [barrel], origin=pivot), "turret_1"))
    lens = v.spike("lens", 0.07, 0.16, (pivot[0], pivot[1] + tip[1] + 0.02, pivot[2] + tip[2]))
    common.glow_mat(lens, palette.LASER_RED)
    objects.append(common.art_group(lens, "turret_1"))

    return objects
