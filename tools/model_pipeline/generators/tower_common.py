"""Shared builder for the Guard, Twin Guard and Warden laser towers.

All three share unit_defs' 1x2x1 cell collider (4x8x4 studs) and the same accent color
(Color3.fromRGB(198, 86, 72)). The game is meant to carry thousands of units, so every model is a handful of
strong low-poly shapes, well under 100 triangles: a sloped plinth, a tapered column, and armored turret heads.

- Guard (corllt): one light turret on top.
- Twin Guard (corhllt): two turrets stacked on the same column, each aiming on its own (unit_defs/defense.luau:
  "a long one on top and a shorter one below"). The weapons fire from offsets (0, 3, 0) and (0, 1, 0) in the
  collider's frame, whose centre is 4 studs up, so the barrels sit about 7 and 5 studs off the ground.
- Warden (corhlt): one heavy, armored turret with a thick barrel.

Barrels point Blender -Y, which build.py's (x, z, -y) conversion turns into Roblox +Z, the way a model faces.
Each turret head is one merged object whose origin is its swivel point on the column's axis, in a rigid piece
(common.art_group) with its muzzle glow, so it turns with its weapon's aim in the game.
"""

from . import common

ACCENT_COLOR = (0.776, 0.337, 0.282, 1.0)  # unit_defs Color3.fromRGB(198, 86, 72)
GLOW_COLOR = (1.0, 0.72, 0.15, 1.0)  # warm amber, deliberately far from the rust-red accent


def _accent_mat(obj):
    common.apply_material(obj, "tower_accent", ACCENT_COLOR, roughness=0.4, metallic=0.1)


def _glow_mat(obj):
    common.apply_material(obj, "tower_glow", GLOW_COLOR, roughness=0.2, metallic=0.0, emission=0.9)


def _head(name, spec, swivel_z):
    """A turret head built about its swivel point, then merged and moved onto the column: a sloped housing with a
    square barrel out of its front (22 triangles, 32 heavy), and a glowing pyramid at the muzzle (6)."""
    w, l, h = spec["width"], spec["length"], spec["height"]
    pieces = [
        # the top face is narrower and pulled back, so the front and sides read as angled armor
        common.drop_bottom(common.tapered_box(f"{name}_housing", w, l, h, w * 0.7, l * 0.6, top_offset=(0.0, l * 0.15))),
    ]
    if spec.get("heavy"):
        # a wider armored skirt round the lower half
        pieces.append(common.drop_bottom(common.tapered_box(f"{name}_skirt", w * 1.18, l * 0.9, h * 0.55, w * 1.05, l * 0.8)))
    barrel_z = h * 0.5
    br, blen = spec["barrel"], spec["barrel_len"]
    barrel = common.box(f"{name}_barrel", br, blen, br)
    barrel.location = (0.0, -l * 0.3 - blen / 2.0, barrel_z - br / 2.0)
    pieces.append(barrel)
    for piece in pieces:
        _accent_mat(piece)
    head = common.merge(name, pieces, origin=(0.0, 0.0, swivel_z))

    glow = common.pyramid(f"{name}_glow", br * 1.3, br * 1.3, br * 1.4)
    glow.rotation_euler = (1.5707963, 0.0, 0.0)  # apex toward -Y, out of the muzzle
    glow.location = (0.0, -l * 0.3 - blen, swivel_z + barrel_z)
    _glow_mat(glow)
    return head, glow


def generate(params, tier):
    """tier: "guard" (one turret), "twin_guard" (two, stacked), or "warden" (one, heavy)."""
    heavy = tier == "warden"
    twin = tier == "twin_guard"

    width = float(params.get("width", 4.0))
    depth = float(params.get("depth", 4.0))
    # `height` is the top of the column, where the (upper) turret swivels.
    default_height = {"guard": 4.7, "twin_guard": 6.1, "warden": 4.9}[tier]
    height = float(params.get("height", default_height))
    s = min(width, depth) / 4.0

    objects = []

    # plinth: one sloped block filling the cell
    plinth_h = (1.3 if heavy else 1.1) * s
    plinth = common.drop_bottom(common.tapered_box("plinth", 3.9 * s, 3.9 * s, plinth_h, 2.9 * s, 2.9 * s))
    common.trim_mat(plinth)
    objects.append(plinth)

    column_w = (1.6 if heavy else 1.25) * s
    column = common.drop_bottom(
        common.tapered_box("column", column_w * 1.25, column_w * 1.25, height - plinth_h, column_w, column_w, origin=(0.0, 0.0, plinth_h))
    )
    common.body_mat(column)
    objects.append(column)

    if heavy:
        heads = [("turret_1", {"width": 2.5 * s, "length": 2.7 * s, "height": 1.5 * s, "barrel": 0.45 * s, "barrel_len": 2.2 * s, "heavy": True}, height)]
    elif twin:
        heads = [
            ("turret_1", {"width": 1.7 * s, "length": 2.0 * s, "height": 1.0 * s, "barrel": 0.28 * s, "barrel_len": 2.1 * s}, height),
            # the lower one is wide, short-barreled, and wraps the column
            ("turret_2", {"width": 2.5 * s, "length": 2.4 * s, "height": 1.05 * s, "barrel": 0.34 * s, "barrel_len": 1.4 * s}, 4.1 * s),
        ]
    else:
        heads = [("turret_1", {"width": 2.0 * s, "length": 2.3 * s, "height": 1.2 * s, "barrel": 0.32 * s, "barrel_len": 1.8 * s}, height)]

    for weapon, (name, spec, z) in enumerate(heads, start=1):
        head, glow = _head(name, spec, z)
        # each head, and the glow at its muzzle, turns with its own weapon's aim (unit_defs' weapons, in order)
        objects.append(common.art_group(head, name, pivot=True, kind="turret", weapon=weapon))
        objects.append(common.art_group(glow, name))

    return objects
