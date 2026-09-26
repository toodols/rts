"""Tutorial UI icon: the four arrow keys in an inverted T (up at the back centre, left / down / right in front),
lying flat with their tops facing +Y (Roblox), each arrow pointing its way as seen from a camera toward +Z looking
down (up points toward -Z, away from the viewer).

Each key is its own art group, `key_up`, `key_left`, `key_down`, `key_right`: its cap (material key_cap) and its
raised arrow (key_glyph), pivoting on the key's centre on the ground. The origin is the middle of the cluster on the
ground. Written to src/shared/ui_art/, not src/shared/art/.
"""

import math

from .shared import tutorial as tc

CATEGORY = "hud"


# in tc.INVERTED_T order, with how far each arrow turns counter-clockwise (Blender, seen from above) from pointing +Y
KEYS = (("up", 0.0), ("left", 90.0), ("down", 180.0), ("right", -90.0))

# an arrow pointing +Y, counter-clockwise: head then shaft
ARROW = ((0.0, 0.56), (-0.46, 0.04), (-0.16, 0.04), (-0.16, -0.52), (0.16, -0.52), (0.16, 0.04), (0.46, 0.04))


def generate(params):
    scale = params.get("arrow_scale", 1.0)

    def glyph(index, x, y, z):
        name, turn = KEYS[index]
        a = math.radians(turn)
        c, s = math.cos(a), math.sin(a)
        polygon = [(scale * (px * c - py * s), scale * (px * s + py * c)) for px, py in ARROW]
        return f"key_{name}", tc.prism(f"arrow_{name}", polygon, z, tc.GLYPH_DEPTH, origin=(x, y))

    return tc.key_cluster(glyph)
