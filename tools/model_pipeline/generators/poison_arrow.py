"""unit_defs/vehicle_t2.luau `poison_arrow` (BAR's corparrow): Cortex's amphibious heavy tank.

A boat-nosed hull that drives along the sea floor: a pointed prow, buoyancy pontoons along both flanks (the
team accent), a snorkel at the back, and a big low hexagonal turret with one long, heavy cannon ending in a
fat muzzle brake -- slow and hard-hitting."""

from .shared import common
from .shared import palette
from .shared import vehicle_t2 as v

CATEGORY = "entity"
DEF = "poison_arrow"
MOUNTS = {
    1: {"pivot": (0, 1.5699, -0.235), "muzzle": (-0.0841, 0.3181, 2.5373)},
}


def generate(params):
    radius = params["collider"]["radius"]
    m = common.Materials(params["color"], palette.HEADLIGHT)
    objects = []

    top_z = 1.12
    # Footprint first: the boat hull, prow forward (14 tris).
    hull = v.loft("hull", [
        (-2.05, 0.26, 0.36, 0.6, 0.82),
        (-1.35, 0.7, 0.72, 0.3, top_z),
        (2.05, 0.7, 0.66, 0.36, top_z - 0.06),
    ], drop=("bottom", "front"))
    objects.append(m.body(hull))

    # Buoyancy pontoons along the flanks, pointed like the prow (10 tris each), over the tracks (8 each).
    for side in (-1, 1):
        x = side * 0.98
        pontoon = v.loft(f"pontoon_{side}", [
            (-1.8, 0.08, 0.06, 0.62, 0.84),
            (-1.2, 0.28, 0.22, 0.44, 1.0),
            (1.9, 0.28, 0.2, 0.44, 0.96),
        ], x=x, drop=("bottom", "left" if side > 0 else "right", "back"))
        objects.append(m.accent(pontoon))
        objects.append(m.trim(v.track(f"track_{side}", x, 3.4, 0.5, 0.5, y=0.25)))

    # Snorkel at the back (6 tris), engine deck grille (2), headlights on the prow (2 each).
    snorkel, _ = v.rod("snorkel", 0.11, 1.25, (-0.46, 1.62, top_z - 0.1), pitch=90.0, sides=3, front_cap=False)
    objects.append(m.trim(snorkel))
    gz = top_z - 0.02
    objects.append(m.trim(v.decal("grille", [(-0.4, 1.2, gz + 0.012), (0.4, 1.2, gz + 0.012),
                                             (0.4, 1.85, gz - 0.012), (-0.4, 1.85, gz - 0.012)])))
    for side in (-1, 1):
        light = v.decal(f"headlight_{side}", [
            (side * 0.1, -1.95, 0.87), (side * 0.36, -1.83, 0.9), (side * 0.36, -1.72, 0.96), (side * 0.1, -1.8, 0.94),
        ], up=(0.0, -0.4, 1.0))
        objects.append(m.glow(light))

    # Turret about its swivel point, set back so the long gun still reaches only the collider's edge (16 tris).
    pivot = (0.0, 0.2, top_z)
    shell = v.frustum("turret_shell", 0.9, 0.66, 0.5, sides=6, turn=30.0)
    m.accent(shell)
    turret = common.merge("turret", [shell], origin=pivot)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # One long gun and its muzzle brake (20 tris).
    reach = radius - pivot[1] - 0.05
    z = 0.28
    barrel, _ = v.rod("barrel", 0.09, reach - 0.6, (0.0, -0.6, z), radius2=0.075)
    brake, _ = v.rod("brake", 0.14, 0.34, (0.0, -reach + 0.34, z), front_cap=True)
    for p in (barrel, brake):
        m.trim(p)
    gun = common.merge("gun", [barrel, brake], origin=pivot)
    objects.append(common.art_group(gun, "turret_1", kind="turret", weapon=1))

    return objects
