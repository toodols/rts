"""unit_defs/vehicle_t1.luau `lasher` (cormist): Cortex's missile truck.

Collider capsule(32, 31, 43): radius 1.95 studs, height 2.82. The tier's wheeled heavy, in under 100 triangles:
a gunmetal flatbed on four big dark wheels with a sloped team-coloured cab, carrying one big team-coloured
missile box pitched up over the cab, its mouth dark. Each wheel rolls on its own hub as it drives.

The def has two racks that never fire together (ground, weapon 1, which does not track; air, weapon 2, which
does). There is only budget for one box, so it is the air rack's: it follows weapon 2's aim once that weapon has
a turret, and faces forward (where the ground rack fires) until then.
"""

from . import common
from . import vehicle_t1_common as v

NAME = "lasher"
ACCENT = v.rgb(176, 122, 88)
PITCH = 34.0  # launcher elevation, degrees


def generate(params):
    accent = tuple(params.get("accent_color", ACCENT))
    objects = []

    # Flatbed chassis (the footprint object): 10, and a sloped team-coloured cab on its nose: 10.
    chassis = v.prism(
        "chassis",
        [(-1.66, 0.26), (1.64, 0.26), (1.64, 0.62), (-1.66, 0.62)],
        width_bottom=1.24,
        width_top=1.16,
    )
    v.body_mat(chassis)
    objects.append(chassis)
    cab = v.prism(
        "cab",
        [(-1.68, 0.62), (-0.66, 0.62), (-0.7, 1.2), (-1.3, 1.2)],
        width_bottom=1.16,
        width_top=0.92,
    )
    v.accent_mat(cab, NAME, accent)
    objects.append(cab)

    # Four big wheels, each its own rolling piece about its hub: 16 each.
    objects += v.rolling_wheels("wheel", 0.36, 0.3, 0.66, (-1.04, 1.06), v.dark_mat)

    # Missile box on the bed, about its ring, pitched up: 12, with a dark mouth.
    pivot = (0.0, 0.5, 0.62)
    box, mouth = v.beam("launcher", 0.86, 0.5, 1.16, (0.0, 0.66, 0.24), pitch_deg=PITCH, skip=())
    box_obj = common.merge("launcher_m", [box], origin=pivot)
    v.accent_mat(box_obj, NAME, accent)
    objects.append(common.art_group(box_obj, "turret_2", pivot=True, kind="turret", weapon=2))

    # the box's mouth, a single dark quad just proud of its front face (2)
    mouth_quad, _ = v.beam("mouth", 0.72, 0.38, 0.01, mouth, pitch_deg=PITCH, skip=("back", "top", "bottom", "left", "right"))
    v.dark_mat(mouth_quad)
    objects.append(common.art_group(common.merge("mouth_m", [mouth_quad], origin=pivot), "turret_2"))

    return v.finish(objects)
