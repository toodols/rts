"""unit_defs/vehicle_t2.luau `quaker` (BAR's cormart): Cortex's mobile artillery.

A low, long tracked chassis with sponsons over open track runs and a wedge nose, and at the back a tall boxy
gun casemate whose long howitzer is laid high, with a heavy cradle and a muzzle brake; a recoil spade hangs off
the tail. Collider capsule(38, 24, 41): radius 1.864, height 2.18 studs -- a low unit, so the gun's elevation
is what gives it its silhouette. 100-triangle budget.
"""

from . import common
from . import vehicle_t2_common as v

ACCENT = v.rgb(120, 150, 196)

PITCH = 36.0  # the howitzer's elevation, degrees


def generate(params):
    radius, height = v.collider(38, 24, 41)
    m = v.Mats("quaker", tuple(params.get("accent_color", ACCENT)))
    objects = []

    L, W = 3.1, 1.86
    hl, hw = L / 2.0, W / 2.0
    top_z = 0.76

    # Footprint first: the chassis, flaring out over the tracks, with a wedge nose (16 tris).
    hull = v.loft("hull", [
        (-hl, 0.5, 0.62, 0.32, 0.46),
        (-hl + 0.62, 0.56, hw, 0.3, top_z),
        (hl, 0.56, hw - 0.04, 0.3, top_z - 0.04),
    ])
    objects.append(m.body(hull))
    for side in (-1, 1):
        objects.append(m.trim(v.track(f"track_{side}", side * (hw - 0.2), L - 0.1, 0.46, 0.34)))

    # Team-colour plate on the wedge nose, a headlight strip across it (2 tris each).
    ny0, nz0, ny1, nz1 = -hl, 0.46, -hl + 0.62, top_z

    def on_nose(x, t, lift=0.012):
        return (x, ny0 + (ny1 - ny0) * t - lift * 0.43, nz0 + (nz1 - nz0) * t + lift * 0.9)

    up = (0.0, -(nz1 - nz0), ny1 - ny0)
    objects.append(m.accent(v.decal("nose_plate", [on_nose(-0.5, 0.45), on_nose(0.5, 0.45), on_nose(0.6, 0.97),
                                                   on_nose(-0.6, 0.97)], up=up)))
    for side in (-1, 1):
        objects.append(m.glow(v.decal(f"headlight_{side}", [on_nose(side * 0.22, 0.12), on_nose(side * 0.42, 0.12),
                                                            on_nose(side * 0.43, 0.3), on_nose(side * 0.23, 0.3)], up=up)))
    # Recoil spade folded up on the tail (8 tris).
    spade = v.block("spade", 0.9, 0.1, 0.4, origin=(0.0, hl + 0.03, 0.18), top=(0.7, 0.1), drop=("bottom", "front"))
    objects.append(m.trim(spade))

    # Casemate turret at the back, about its swivel point (10 tris), with a cupola (10).
    pivot = (0.0, 0.15, top_z - 0.02)
    shell = [
        v.block("casemate", 1.2, 1.4, 0.56, origin=(0.0, 0.12, 0.0), top=(0.98, 0.92), top_offset=(0.0, 0.2)),
        v.frustum("cupola", 0.2, 0.15, 0.14, origin=(0.28, 0.46, 0.56), sides=4, turn=45.0),
    ]
    for p in shell:
        m.accent(p)
    turret = common.merge("turret", shell, origin=pivot)
    objects.append(common.art_group(turret, "turret_1", pivot=True, kind="turret", weapon=1))

    # The howitzer: cradle, barrel and muzzle brake (30 tris), laid at PITCH out of the casemate's face.
    trunnion = (0.0, -0.22, 0.34)
    cradle, _ = v.rod("cradle", 0.15, 0.8, trunnion, pitch=PITCH)
    barrel, tip = v.rod("barrel", 0.075, 1.7, trunnion, pitch=PITCH)
    d = v.direction(PITCH)
    brake, _ = v.rod("brake", 0.12, 0.22, tuple(v.Vector(tip) - d * 0.22), pitch=PITCH)
    for p in (cradle, barrel, brake):
        m.trim(p)
    gun = common.merge("gun", [cradle, barrel, brake], origin=pivot)
    objects.append(common.art_group(gun, "turret_1", kind="turret", weapon=1))

    v.check_fit(objects, radius, height, "quaker")
    return objects
