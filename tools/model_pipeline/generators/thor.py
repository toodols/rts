"""unit_defs/t3.luau `thor` (BAR armthor): Armada's experimental lightning tank.

Held to 100 triangles. After BAR's
model: a broad, flat armoured hull riding on four separate track pods, one at each corner, with glowing blue panels
along their tops, a squat team-coloured turret in the middle carrying the twin tesla barrels of the lightning cannon,
and an EMP emitter jutting from each flank.

The turret and its barrels are one piece following weapon 1's aim (the lightning cannon's turret); everything else
is the static base.
"""

from .shared import common
from .shared import palette
from .shared import vehicle_t2 as v

CATEGORY = "entity"
DEF = "thor"
# Armada's tesla blue, the glow panels on BAR's model
DEF = "thor"
MOUNTS = {
    1: {"pivot": (0, 1.5111, -0.1767), "muzzle": (-0.5791, 0.3535, 2.8131)},
}


def generate(params):
    radius = params["collider"]["radius"]
    m = common.Materials(params["color"], palette.HEADLIGHT)
    objects = []

    hl = 1.9  # half the hull's length, fitted in the collider circle with the pods
    deck_z = 0.95

    # Footprint first: the centre hull between the pods, a sloped glacis in front and a shorter slope at the back
    # (10 tris with its two end caps, which show between the pods).
    hull = v.prism_x("hull", [(-hl + 0.1, 0.25), (-hl + 0.75, deck_z), (hl - 0.45, deck_z), (hl - 0.1, 0.45),
                              (hl - 0.1, 0.25)], 2.0)
    objects.append(m.body(hull))

    # Four track pods, one at each corner, standing clear of each other fore and aft (8 tris each), each with a
    # glowing blue panel along its top (2 each).
    pod_w, pod_len, pod_h = 0.72, 1.55, 0.72
    for side in (-1, 1):
        x = side * 1.36
        for end in (-1, 1):
            y = end * (hl - pod_len / 2.0)
            pod = v.track(f"pod_{side}_{end}", x, pod_len, pod_h, pod_w, y=y, nose=0.5)
            objects.append(m.trim(pod))
            z = pod_h + 0.01
            panel = v.decal(f"panel_{side}_{end}", [(x - 0.22, y - 0.42, z), (x + 0.22, y - 0.42, z),
                                                     (x + 0.22, y + 0.42, z), (x - 0.22, y + 0.42, z)])
            objects.append(m.glow(panel, palette.ELECTRIC_BLUE))

    # The EMP emitters: a short three-sided barrel out of each flank, over the gap between the pods (7 tris each).
    for side in (-1, 1):
        emitter, _ = v.rod(f"emp_{side}", 0.18, 0.55, (side * 1.0, 0.0, 0.62), yaw=side * 90.0, sides=3, roll=90.0)
        objects.append(m.trim(emitter))

    # Turret about its swivel point (10 tris), with the twin tesla barrels, thick at the breech and tapering to the
    # muzzle, reaching as far as the collider lets them at any yaw (10 tris each), and a glowing coil plate on top.
    pivot = (0.0, 0.15, deck_z)
    shell = common.block("turret_shell", 1.5, 1.7, 0.6, top=(1.1, 1.2), top_offset=(0.0, 0.12), at=(0.0, 0.0, 0.0), drop=('bottom',))
    m.accent(shell)
    coil = v.decal("coil", [(-0.35, -0.3, 0.61), (0.35, -0.3, 0.61), (0.35, 0.35, 0.61), (-0.35, 0.35, 0.61)])
    m.glow(coil, palette.ELECTRIC_BLUE)
    reach = radius - abs(pivot[1]) - 0.08
    parts = [shell, coil]
    for side in (-1, 1):
        x = side * 0.3
        length = (reach ** 2 - x ** 2) ** 0.5 - 0.55
        barrel, _ = v.rod(f"barrel_{side}", 0.2, length, (x, -0.55, 0.3), sides=4, radius2=0.11)
        parts.append(m.trim(barrel))
    for part in parts:
        turret_part = common.merge(f"turret_{part.name}", [part], origin=pivot)
        objects.append(common.art_group(turret_part, "turret_1", kind="turret", weapon=1))
    common.art_group(objects[-len(parts)], "turret_1", pivot=True, kind="turret", weapon=1)

    return objects
