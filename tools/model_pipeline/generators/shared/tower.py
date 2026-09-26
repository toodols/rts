"""Shared builder for the Guard, Twin Guard and Warden laser towers.

The game is meant to carry thousands of units, so every model is a handful of strong low-poly shapes, well under
100 triangles: a sloped plinth, a tapered column, and armored turret heads, sized by the tower's own generator.

- Guard (corllt): one light turret on top.
- Twin Guard (corhllt): two turrets stacked on the same column, each aiming on its own (unit_defs/defense.luau:
  "a long one on top and a shorter one below").
- Warden (corhlt): one heavy, armored turret with a thick barrel.

Barrels point Blender -Y, which build.py's (x, z, -y) conversion turns into Roblox +Z, the way a model faces.
Each turret head is one merged object whose origin is its swivel point on the column's axis, in a rigid piece
(common.art_group) with its muzzle glow, so it turns with its weapon's aim in the game.
"""

from . import common
from . import palette


def _head(name, spec, swivel_z, accent):
    """A turret head built about its swivel point, then merged and moved onto the column: a sloped housing with a
    square barrel out of its front (22 triangles, 32 heavy), and a glowing pyramid at the muzzle (6)."""
    w, l, h = spec["width"], spec["length"], spec["height"]
    pieces = [
        # the top face is narrower and pulled back, so the front and sides read as angled armor
        common.drop_bottom(common.block(f"{name}_housing", w, l, h, top=(w * 0.7, l * 0.6), top_offset=(0.0, l * 0.15))),
    ]
    if spec["heavy"]:
        # a wider armored skirt round the lower half
        pieces.append(common.drop_bottom(common.block(f"{name}_skirt", w * 1.18, l * 0.9, h * 0.55, top=(w * 1.05, l * 0.8))))
    barrel_z = h * 0.5
    br, blen = spec["barrel"], spec["barrel_len"]
    barrel = common.box(f"{name}_barrel", br, blen, br)
    barrel.location = (0.0, -l * 0.3 - blen / 2.0, barrel_z - br / 2.0)
    pieces.append(barrel)
    for piece in pieces:
        common.accent_mat(piece, accent)
    head = common.merge(name, pieces, origin=(0.0, 0.0, swivel_z))

    glow = common.pyramid(f"{name}_glow", br * 1.3, br * 1.3, br * 1.4)
    glow.rotation_euler = (1.5707963, 0.0, 0.0)  # apex toward -Y, out of the muzzle
    glow.location = (0.0, -l * 0.3 - blen, swivel_z + barrel_z)
    common.glow_mat(glow, palette.AMBER)
    return head, glow


def generate(params, column_top, plinth_height, column_width, heads):
    """A tower on its def's footprint. Its column rises to `column_top` studs; the plinth's height and the column's
    width are for a one-cell footprint, as is each of `heads`, top first: its housing's `width`, `length` and
    `height`, its `barrel`'s thickness and `barrel_len`, whether it is `heavy` (an armored skirt), and `swivel`,
    the height it turns at when that is not the column's top."""
    collider = params["collider"]
    s = min(collider["width"], collider["length"]) / 4.0

    objects = []

    # plinth: one sloped block filling the cell
    plinth_h = plinth_height * s
    plinth = common.drop_bottom(common.block("plinth", 3.9 * s, 3.9 * s, plinth_h, top=(2.9 * s, 2.9 * s)))
    common.trim_mat(plinth)
    objects.append(plinth)

    column_w = column_width * s
    column = common.drop_bottom(
        common.block("column", column_w * 1.25, column_w * 1.25, column_top - plinth_h, top=(column_w, column_w), origin=(0.0, 0.0, plinth_h))
    )
    common.body_mat(column)
    objects.append(column)

    for weapon, head_spec in enumerate(heads, start=1):
        name = f"turret_{weapon}"
        spec = {key: head_spec[key] * s for key in ("width", "length", "height", "barrel", "barrel_len")}
        spec["heavy"] = head_spec.get("heavy", False)
        z = head_spec["swivel"] * s if "swivel" in head_spec else column_top
        head, glow = _head(name, spec, z, params["color"])
        # each head, and the glow at its muzzle, turns with its own weapon's aim (unit_defs' weapons, in order)
        objects.append(common.art_group(head, name, pivot=True, kind="turret", weapon=weapon))
        objects.append(common.art_group(glow, name))

    return objects
