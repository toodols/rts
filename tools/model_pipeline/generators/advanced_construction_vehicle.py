"""unit_defs/vehicle_t2.luau `advanced_construction_vehicle` (BAR's coracv): Cortex's tier-two builder.

A broad tracked hull with a team-colour cab up front on the left, and on the back deck a high-vis yellow
nanolathe crane -- turntable, raised boom, a forearm angled down and a glowing emitter nozzle -- that turns
toward whatever it is building. Collider capsule(36, 36, 47): radius 2.136, height 3.27 studs. 100-triangle
budget.
"""

from . import common
from . import vehicle_t2_common as v

ACCENT = v.rgb(226, 178, 74)


def generate(params):
    radius, height = v.collider(36, 36, 47)
    m = v.Mats("advanced_construction_vehicle", tuple(params.get("accent_color", ACCENT)))
    objects = []

    L, W = 3.6, 2.16
    hl, hw = L / 2.0, W / 2.0
    deck = 0.92

    # Footprint first: the hull, a sloped bow and a flat working deck, flared over the tracks (16 tris).
    hull = v.loft("hull", [
        (-hl, 0.72, 0.9, 0.34, 0.56),
        (-hl + 0.6, 0.78, hw, 0.3, deck),
        (hl, 0.78, hw, 0.3, deck),
    ])
    objects.append(m.body(hull))
    for side in (-1, 1):
        objects.append(m.trim(v.track(f"track_{side}", side * (hw - 0.26), L - 0.1, 0.5, 0.5)))

    # Cab forward on the left (10 tris) with a dark windscreen (2); headlights on the bow (2 each).
    cx, cy0, cy1, ch = -0.5, -hl + 0.62, -hl + 1.62, 0.66
    cab = v.block("cab", 0.98, cy1 - cy0, ch, origin=(cx, (cy0 + cy1) / 2.0, deck), top=(0.8, 0.62),
                  top_offset=(0.0, 0.16))
    objects.append(m.accent(cab))
    fy_top = (cy0 + cy1) / 2.0 + 0.16 - 0.31

    def cab_front(x, t):
        return (cx + x, cy0 + (fy_top - cy0) * t - 0.012, deck + ch * t + 0.005)

    up = (0.0, -ch, fy_top - cy0)
    objects.append(m.trim(v.decal("windscreen", [cab_front(-0.44, 0.45), cab_front(0.44, 0.45),
                                                 cab_front(0.39, 0.9), cab_front(-0.39, 0.9)], up=up)))
    by0, bz0, by1, bz1 = -hl, 0.56, -hl + 0.6, deck
    bow_up = (0.0, -(bz1 - bz0), by1 - by0)
    for side in (-1, 1):
        def bow(x, t):
            return (x, by0 + (by1 - by0) * t - 0.012, bz0 + (bz1 - bz0) * t + 0.01)
        objects.append(m.glow(v.decal(f"headlight_{side}", [bow(side * 0.55, 0.3), bow(side * 0.8, 0.3),
                                                            bow(side * 0.81, 0.55), bow(side * 0.56, 0.55)], up=bow_up)))

    # Team-colour hazard plate on the back deck (2 tris).
    dz = deck + 0.01
    objects.append(m.accent(v.decal("deck_plate", [(-0.9, hl - 0.5, dz), (0.9, hl - 0.5, dz), (0.9, hl - 0.15, dz),
                                                   (-0.9, hl - 0.15, dz)])))

    # Nanolathe crane about its turntable: turntable (10 tris), boom and forearm (8 each), emitter (10).
    pivot = (0.25, 0.55, deck)
    turntable = v.block("turntable", 0.8, 0.8, 0.28, top=(0.64, 0.64))
    shoulder = (0.0, 0.2, 0.2)
    boom, elbow = v.rod("boom", 0.15, 1.2, shoulder, pitch=50.0, front_cap=False)
    fore, wrist = v.rod("forearm", 0.12, 0.72, elbow, pitch=-52.0, front_cap=False)
    arm = [turntable, boom, fore]
    for p in arm:
        m.hivis(p)
    crane = common.merge("crane", arm, origin=pivot)
    objects.append(common.art_group(crane, "nanolathe", pivot=True, kind="work"))
    nozzle, _ = v.rod("emitter", 0.08, 0.22, wrist, pitch=-52.0, radius2=0.19)
    m.glow(nozzle, color=v.NANO_COLOR, name="nano")
    nozzle = common.merge("emitter", [nozzle], origin=pivot)
    objects.append(common.art_group(nozzle, "nanolathe", kind="work"))

    v.check_fit(objects, radius, height, "advanced_construction_vehicle")
    return objects
