"""unit_defs/vehicle_t1.luau `janus` (armjanus): Arm's twin rocket launcher.

A long, low tracked hull, lower than any other of the
tier, in under 100 triangles: a gunmetal hull with a sloped nose between two dark track runs, a low team-coloured
turret ring set back on the roof, and on either side of it a stubby team-coloured rocket pod pitched up, its mouth
dark. BAR slaves the second pod to the first; here the def has them as two weapons, one each side (offsets x -0.6
and +0.6), so each pod is its own swivel following its own weapon's aim (turret_1 on the left, turret_2 on the
right), and the two point the same way whenever they fire together.
"""

from .shared import common
from .shared import vehicle_t1 as v

CATEGORY = "entity"
DEF = "janus"
MOUNTS = {
    1: {"pivot": (-0.7411, 0.5731, -0.2571), "muzzle": (-0.2594, 0.1869, 0.5223)},
    2: {"pivot": (0.7411, 0.5731, -0.2571), "muzzle": (-0.2594, 0.1869, 0.5223)},
}
PITCH = 18.0  # pod elevation, degrees


def generate(params):
    accent = params["color"]
    m = common.Materials(accent)
    objects = []

    # Hull (the footprint object): 18 triangles, a sloped nose at the front (-Y) and a short rear deck.
    hull = v.prism(
        "hull",
        [(-1.4, 0.24), (-0.9, 0.54), (1.1, 0.56), (1.4, 0.4), (1.36, 0.14), (-1.2, 0.14)],
        width_bottom=1.26,
        width_top=1.12,
    )
    common.body_mat(hull)
    objects.append(hull)

    # Tracks: their lower run, a tapered block without floor or inner face under each flank: 8 each.
    tracks = [
        common.block(f"track_{side}", 0.32, 2.5, 0.36, top=(0.32, 2.76), origin=(side * 0.76, 0.0, 0.0), drop=("bottom", "left" if side > 0 else "right"))
        for side in (-1.0, 1.0)
    ]
    m.paint("trim", *tracks)
    objects.append(common.merge("tracks", tracks))

    # A low turret ring on the roof, set back, between the pods: 10.
    ring = common.block("ring", 0.62, 0.7, 0.14, top=(0.5, 0.56), origin=(0.0, 0.2, 0.55), drop=('bottom',))
    common.accent_mat(ring, accent)
    objects.append(ring)

    # The two pods, each about its own swivel beside the ring, pitched up (10 each), with a dark mouth (2 each).
    for weapon, side in ((1, -1.0), (2, 1.0)):
        pivot = (side * 0.6, 0.24, 0.56)
        pod, mouth = v.beam(f"pod_{weapon}", 0.42, 0.34, 0.92, (0.0, 0.44, 0.06), pitch_deg=PITCH, drop=())
        pod_obj = common.merge(f"pod_{weapon}_m", [pod], origin=pivot)
        common.accent_mat(pod_obj, accent)
        objects.append(common.art_group(pod_obj, f"turret_{weapon}", pivot=True, kind="turret", weapon=weapon))

        mouth_quad, _ = v.beam(
            f"mouth_{weapon}", 0.32, 0.24, 0.01, mouth, pitch_deg=PITCH, drop=("back", "top", "bottom", "left", "right")
        )
        common.trim_mat(mouth_quad)
        objects.append(common.art_group(common.merge(f"mouth_{weapon}_m", [mouth_quad], origin=pivot), f"turret_{weapon}"))

    return objects
