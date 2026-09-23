"""Shared builder for the construction turret and its advanced upgrade.

Both are stationary builders (no weapon) with a small footprint (unit_defs/building.luau: `construction_turret` is
a 1x1x1 cell box, `advanced_construction_turret` a 1x2x1 cell box, i.e. 4x4x4 and 4x8x4 studs). Same low-poly
language as the laser towers, well under 100 triangles: a sloped plinth, a column, and a head carrying a
nanolathe arm that reaches forward and down to a glowing emitter -- "this thing builds", not "this thing
shoots". The advanced turret stands taller and carries a second arm.

The head and its arms are one merged object whose origin is the swivel point on the column's axis, in a rigid
piece with the emitter glows (common.art_group, kind="work"), so it turns toward whatever it is building. The
arms point Blender -Y, i.e. Roblox +Z, the model's front.
"""

from . import common

DEFAULT_ACCENT_COLOR = (0.886, 0.698, 0.290, 1.0)  # unit_defs Color3.fromRGB(226, 178, 74)
DEFAULT_GLASS_COLOR = (0.35, 0.95, 0.75, 1.0)  # nanolathe green-cyan


def _arm(name, x, shoulder_z, reach, thick):
    """A bent arm as two struts, raised forward from the shoulder and angled down from the elbow (24 triangles).
    Returns (pieces, tip) in the head's frame."""
    upper, elbow = common.strut(f"{name}_upper", thick, thick, reach * 0.5, (x, 0.0, shoulder_z), tilt_x=30.0)
    fore, tip = common.strut(f"{name}_fore", thick * 0.8, thick * 0.8, reach * 0.55, elbow, tilt_x=115.0)
    return [upper, fore], tip


def generate(params, advanced):
    width = float(params.get("width", 4.0))
    depth = float(params.get("depth", 4.0))
    s = min(width, depth) / 4.0
    # `height` is the top of the column, where the head swivels.
    height = float(params.get("height", (4.6 if advanced else 2.1) * s))
    accent_color = tuple(params.get("accent_color", DEFAULT_ACCENT_COLOR))
    glass_color = tuple(params.get("glass_color", DEFAULT_GLASS_COLOR))

    def accent_mat(obj):
        common.apply_material(obj, "turret_accent", accent_color, roughness=0.38, metallic=0.1)

    def glass_mat(obj):
        common.apply_material(obj, "turret_glass", glass_color, roughness=0.15, metallic=0.0, emission=1.0)

    objects = []

    plinth_h = 0.85 * s
    plinth = common.drop_bottom(common.tapered_box("plinth", 3.9 * s, 3.9 * s, plinth_h, 3.0 * s, 3.0 * s))
    common.trim_mat(plinth)
    objects.append(plinth)

    column_w = 1.25 * s
    column = common.drop_bottom(
        common.tapered_box("column", column_w * 1.2, column_w * 1.2, height - plinth_h, column_w, column_w, origin=(0.0, 0.0, plinth_h))
    )
    common.body_mat(column)
    objects.append(column)

    # the head, built around the swivel point (0, 0, 0)
    hw, hl, hh = (1.8 * s, 1.9 * s, 1.0 * s) if advanced else (1.6 * s, 1.7 * s, 0.9 * s)
    pieces = [common.drop_bottom(common.tapered_box("housing", hw, hl, hh, hw * 0.72, hl * 0.62, top_offset=(0.0, hl * 0.12)))]
    thick = 0.3 * s
    reach = (2.4 if advanced else 2.2) * s
    arms = [hw * 0.3, -hw * 0.3] if advanced else [0.0]
    tips = []
    for i, x in enumerate(arms):
        arm_pieces, tip = _arm(f"arm_{i + 1}", x, hh * 0.8, reach * (1.0 if i == 0 else 0.85), thick)
        pieces += arm_pieces
        tips.append(tip)
    for piece in pieces:
        accent_mat(piece)
    head = common.merge("head", pieces, origin=(0.0, 0.0, height))
    # the head, arms and emitters turn together toward whatever the turret is building
    objects.append(common.art_group(head, "head", pivot=True, kind="work"))

    for i, t in enumerate(tips):
        glow = common.octahedron(f"emitter_{i + 1}", thick * 0.75, origin=(t[0], t[1], height + t[2]))
        glass_mat(glow)
        objects.append(common.art_group(glow, "head"))

    return objects
