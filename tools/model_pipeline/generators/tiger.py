"""unit_defs/vehicle_t2.luau `tiger` (BAR's correap): Cortex's heavy assault tank.

A low, wide tracked hull with a steep glacis and heavy team-colour armor over both tracks, and a broad sloped
turret carrying twin cannons -- the fast-firing gun that makes it good at most jobs. Collider capsule(34, 34,
38): radius 1.727, height 3.09 studs. 100-triangle budget.
"""

from . import common
from . import vehicle_t2_common as v

ACCENT = v.rgb(176, 122, 88)


def generate(params):
    radius, height = v.collider(34, 34, 38)
    m = v.Mats("tiger", tuple(params.get("accent_color", ACCENT)))
    objects = []

    L, W = 2.84, 1.9  # hull footprint, fitted in the collider circle
    hl, hw = L / 2.0, W / 2.0
    deck_z = 0.9

    # Footprint first: the centre deck between the armored track covers, glacis in front (8 tris).
    deck = v.prism_x("deck", [(-hl + 0.05, 0.3), (-hl + 0.5, deck_z), (hl - 0.33, deck_z), (hl - 0.05, 0.6), (hl - 0.05, 0.3)],
                     1.02, caps=())
    objects.append(m.body(deck))

    # Armor over the tracks (11 tris each), each with a team-colour stripe along its top (2).
    skirt_w = 0.45
    for side in (-1, 1):
        x = side * (hw - skirt_w / 2.0)
        skirt = v.prism_x(f"skirt_{side}", [(-hl, 0.42), (-hl + 0.45, 0.96), (hl - 0.3, 0.96), (hl, 0.66), (hl, 0.42)],
                          skirt_w, x=x, caps=("+x",) if side > 0 else ("-x",))
        objects.append(m.body(skirt))
        sz = 0.965
        stripe = v.decal(f"stripe_{side}", [(x - 0.1, -hl + 0.5, sz), (x + 0.1, -hl + 0.5, sz),
                                             (x + 0.1, hl - 0.36, sz), (x - 0.1, hl - 0.36, sz)])
        objects.append(m.accent(stripe))
        objects.append(m.trim(v.track(f"track_{side}", side * (hw - 0.21), L - 0.08, 0.5, 0.4)))

    # Headlights on the glacis and an engine grille on the rear deck (2 tris each).
    gy0, gz0, gy1, gz1 = -hl + 0.05, 0.3, -hl + 0.5, deck_z
    for side in (-1, 1):
        a, b = 0.25, 0.42
        x0, x1 = side * 0.18, side * 0.4
        p0 = (gy0 + (gy1 - gy0) * a - 0.012, gz0 + (gz1 - gz0) * a + 0.009)
        p1 = (gy0 + (gy1 - gy0) * b - 0.012, gz0 + (gz1 - gz0) * b + 0.009)
        light = v.decal(f"headlight_{side}", [(x0, p0[0], p0[1]), (x1, p0[0], p0[1]), (x1, p1[0], p1[1]),
                                               (x0, p1[0], p1[1])], up=(0.0, -0.8, 0.6))
        objects.append(m.glow(light))
    gz = deck_z + 0.01
    grille = v.decal("grille", [(-0.4, hl - 0.75, gz), (0.4, hl - 0.75, gz), (0.4, hl - 0.34, gz), (-0.4, hl - 0.34, gz)])
    objects.append(m.trim(grille))

    # Turret about its swivel point (10 tris), guns separate so they can be dark (28 tris).
    pivot = (0.0, 0.05, deck_z)
    turret = v.block("turret_shell", 1.04, 1.3, 0.46, origin=(0.0, 0.1, 0.0), top=(0.76, 0.8), top_offset=(0.0, 0.14))
    m.accent(turret)
    turret = common.merge("turret", [turret], origin=pivot)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    guns = [v.block("mantlet", 0.46, 0.24, 0.3, origin=(0.0, -0.58, 0.06), drop=("bottom", "back"))]
    reach = radius - pivot[1] - 0.04
    for side in (-1, 1):
        barrel, _ = v.rod(f"barrel_{side}", 0.075, reach - 0.66, (side * 0.14, -0.66, 0.22))
        guns.append(barrel)
    for p in guns:
        m.trim(p)
    gun_block = common.merge("guns", guns, origin=pivot)
    objects.append(common.art_group(gun_block, "turret_1", kind="turret", weapon=1))

    v.check_fit(objects, radius, height, "tiger")
    return objects
