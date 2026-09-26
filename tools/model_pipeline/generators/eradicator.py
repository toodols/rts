"""unit_defs `eradicator` (corerad): a heavy anti-air battery, but squat, as BAR's is
(55 x 36 x 48 elmos). Under 100 triangles.

A low, wide sloped bunker, and on it a broad armored turret with two dark yoke plates holding one big
launcher block pitched up at the sky: eight lit missile cells in two rows across its face, for its bursts of
four. The whole head yaws with weapon 1.
"""

from .shared import defense_a as d

CATEGORY = "entity"
DEF = "eradicator"
MOUNTS = {
    1: {"pivot": (0, 1.6, 0), "muzzle": (-2.15, 0, 2.55)},
}
SWIVEL_Z = 1.6
ELEV = 35.0


def generate(params):
    w = params["collider"]["width"]
    base = d.Parts()
    # the tower line's sloped plinth, broad and low: dark walls, a gunmetal deck
    base.loft([d.square(w - 0.2, 0.0), d.square(6.0, SWIVEL_Z)], side="trim", top="body")

    head = d.Parts()
    fr = d.Frame()
    head.block_u(fr, 0.0, 0.25, 0.0, 1.35, (4.3, 4.6), (3.5, 3.1), top_shift_f=-0.5,
                 tags={"all": "accent", "bottom": None})
    # a dark power block on the turret's back, with a sensor spike on it
    head.block_u(fr, 0.0, -2.1, 0.2, 1.2, (2.4, 1.0), (2.2, 0.8), tags={"all": "trim", "bottom": None, "fore": None})
    head.cone_f(d.Frame(origin=(0.7, 2.1, 1.15), elev=90.0), 4, 0.22, 0.0, 1.0, tag="trim")
    # yoke plates either side of the launcher
    for side in (-1.0, 1.0):
        head.block_u(fr, side * 2.08, 0.0, 0.3, 3.4, (0.36, 2.7), (0.36, 1.2), top_shift_f=0.1,
                     tags={"all": "trim", "bottom": None, "left" if side > 0 else "right": None})

    pod = d.Frame(origin=(0.0, 0.0, 2.5), elev=ELEV)
    head.block_f(pod, 0.0, 0.0, -1.75, 1.75, (3.8, 1.9), (3.55, 1.72), tags={"all": "accent", "front": "trim"})
    # a dark clamp band around the launcher where the yoke holds it
    head.block_f(pod, 0.0, 0.0, -0.25, 0.25, (3.86, 1.96), tags={"all": "trim", "back": None, "front": None})
    for x in (-1.25, -0.42, 0.42, 1.25):
        for u in (-0.4, 0.4):
            head.quad_f(pod, x, 1.755, u, 0.5, 0.5)

    objects = d.base_objects(base, "trim", params["color"])
    objects += d.head_objects(head, (0.0, 0.0, SWIVEL_Z), params["color"])
    return objects
