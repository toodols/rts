"""unit_defs/air_t2.luau `tyrannus`: the flying fortress.

Collider capsule(90, 50, 110): radius 110/22 = 5.0 studs, height 50/11 = 4.55. Faceted low-poly, under 100
triangles. A huge armoured gunship that hovers: a long, wide, squared hull with a raised bridge and a dark sloped
glacis on its nose, four big lift fan ducts hugging its flanks (the team-coloured accent) glowing underneath, a heavy
laser barrel either side of the nose, where its two lasers fire from (air_t2's weapon offsets), and a missile box on
its back for its anti air missiles. Nothing moves: its lasers fire wherever its target is.
"""

from . import air_t1_common as air
from . import common

ACCENT = air.rgb(150, 90, 80)
RADIUS, HEIGHT = 110 / 22, 50 / 11


def generate(params):
    zc = 2.40
    objects = []

    hull = air.loft("hull", [
        (-3.70, zc - 0.25, 0.95, 0.60),
        (-2.20, zc, 1.60, 1.05),
        (3.60, zc + 0.10, 1.25, 0.80),
    ], sides=4)
    common.body_mat(hull)
    objects.append(hull)

    top = zc + 1.00 * 0.7071
    bridge = air.block("bridge", 1.40, 1.60, 0.60, 1.00, 1.10, top_offset=(0.0, 0.10), origin=(0.0, -1.10, top - 0.08),
                       open_bottom=True)
    common.body_mat(bridge)
    objects.append(bridge)
    glazing = air.plate("glazing", (0.0, -1.86, top + 0.28), (0.52, 0, 0), (0, 0.10, 0.18), (0, -1, 0.5))
    air.glass_mat(glazing)
    objects.append(glazing)

    trims, accents, glows = [], [], []
    trims.append(air.plate("glacis", (0.0, -3.00, zc + 0.36), (0.70, 0, 0), (0, 0.55, 0.28), (0, -0.5, 1)))
    # Heavy laser barrels either side of the nose: long dark spikes.
    for side in (-1.0, 1.0):
        x, z = side * 1.30, zc - 0.40
        trims.append(air.tetra(
            f"laser_{side:+.0f}",
            (x, -4.70, z),
            (x - 0.22, -2.00, z + 0.10),
            (x + 0.22, -2.00, z + 0.10),
            (x, -2.00, z - 0.25),
        ))
    trims.append(air.block("missile_box", 1.30, 1.30, 0.60, 1.20, 1.20, origin=(0.0, 1.40, top - 0.20),
                           open_bottom=True))

    # Four lift fan ducts against its flanks, each a squat box open underneath, where its fan glows.
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            cx, cy = sx * 2.05, sy * 1.95 - 0.20
            duct = air.block(f"duct_{sx:+.0f}{sy:+.0f}", 1.80, 1.80, 0.70, 1.60, 1.60, origin=(cx, cy, zc - 0.45))
            # its bottom (0) and the side pressed against the hull (3 is +X, 5 is -X) are never seen
            air.drop_faces(duct, [0, 5 if sx > 0 else 3])
            accents.append(duct)
            glows.append(air.plate(f"fan_{sx:+.0f}{sy:+.0f}", (cx, cy, zc - 0.43), (0.70, 0, 0), (0, 0.70, 0),
                                   (0, 0, -1)))

    for obj in accents:
        air.accent_mat(obj, "tyrannus", ACCENT)
    for obj in trims:
        common.trim_mat(obj)
    for obj in glows:
        air.glow_mat(obj)
    objects += accents + trims + glows

    air.flat(objects)
    air.check_fit(objects, RADIUS, HEIGHT, "tyrannus")
    return objects
