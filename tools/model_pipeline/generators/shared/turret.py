"""Shared builder for the construction turret and its advanced upgrade.

Both are stationary builders (no weapon) on a one-cell footprint, their def's. Same low-poly
language as the laser towers, well under 100 triangles: a sloped plinth, a column, and a head carrying a
nanolathe arm that reaches forward and down to a glowing emitter -- "this thing builds", not "this thing
shoots". The advanced turret stands taller and carries a second arm.

The head and its arms are one merged object whose origin is the swivel point on the column's axis, in a rigid
piece with the emitter glows (common.art_group, kind="work"), so it turns toward whatever it is building. The
arms point Blender -Y, i.e. Roblox +Z, the model's front.
"""

from . import common


def _arm(name, x, shoulder_z, reach, thick):
    """A bent arm as two struts, raised forward from the shoulder and angled down from the elbow (24 triangles).
    Returns (pieces, tip) in the head's frame."""
    upper, elbow = common.strut(f"{name}_upper", thick, thick, reach * 0.5, (x, 0.0, shoulder_z), tilt_x=30.0)
    fore, tip = common.strut(f"{name}_fore", thick * 0.8, thick * 0.8, reach * 0.55, elbow, tilt_x=115.0)
    return [upper, fore], tip


def generate(params, column_top, head, reach, arms):
    """A turret on its def's footprint, its head swivelling at `column_top`; the rest is for a one-cell footprint:
    `head` is the housing's (width, length, height), `reach` how far its first arm reaches (any other reaches 0.85
    of it), and `arms` where each arm sits across the housing, as a fraction of its width."""
    collider = params["collider"]
    s = min(collider["width"], collider["length"]) / 4.0
    height = column_top * s
    accent = params["color"]

    objects = []

    plinth_h = 0.85 * s
    plinth = common.drop_bottom(common.block("plinth", 3.9 * s, 3.9 * s, plinth_h, top=(3.0 * s, 3.0 * s)))
    common.trim_mat(plinth)
    objects.append(plinth)

    column_w = 1.25 * s
    column = common.drop_bottom(
        common.block("column", column_w * 1.2, column_w * 1.2, height - plinth_h, top=(column_w, column_w), origin=(0.0, 0.0, plinth_h))
    )
    common.body_mat(column)
    objects.append(column)

    # the head, built around the swivel point (0, 0, 0)
    hw, hl, hh = (d * s for d in head)
    pieces = [common.drop_bottom(common.block("housing", hw, hl, hh, top=(hw * 0.72, hl * 0.62), top_offset=(0.0, hl * 0.12)))]
    thick = 0.3 * s
    reach = reach * s
    tips = []
    for i, across in enumerate(arms):
        arm_pieces, tip = _arm(f"arm_{i + 1}", hw * across, hh * 0.8, reach * (1.0 if i == 0 else 0.85), thick)
        pieces += arm_pieces
        tips.append(tip)
    for piece in pieces:
        common.accent_mat(piece, accent)
    head = common.merge("head", pieces, origin=(0.0, 0.0, height))
    # the head, arms and emitters turn together toward whatever the turret is building
    objects.append(common.art_group(head, "head", pivot=True, kind="work"))

    for i, t in enumerate(tips):
        glow = common.octahedron(f"emitter_{i + 1}", thick * 0.75, origin=(t[0], t[1], height + t[2]))
        common.nano_mat(glow)
        objects.append(common.art_group(glow, "head"))

    return objects
