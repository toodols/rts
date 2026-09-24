"""Tutorial UI icon: the W A S D keys in an inverted T (W at the back centre, A S D in front), lying flat with their
tops facing +Y (Roblox), letters reading upright from a camera toward +Z looking down.

Each key is its own art group, `key_w`, `key_a`, `key_s`, `key_d`: its cap (material key_cap) and its raised letter
(key_glyph), pivoting on the key's centre on the ground, so the HUD can light one up as it is pressed. The origin
is the middle of the cluster on the ground. Written to src/shared/ui_art/, not src/shared/art/.
"""

from . import tutorial_common as tc

MAX_TRIANGLES = tc.MAX_TRIANGLES
RECENTRE = False

KEYS = ("W", "A", "S", "D")  # in tc.INVERTED_T order: back centre, then left, middle, right in front


def generate(params):
    size = params.get("letter_size", 1.35)

    def glyph(index, x, y, z):
        letter = KEYS[index]
        return f"key_{letter.lower()}", tc.text_glyph(f"glyph_{letter}", letter, size, x, y, z)

    return tc.key_cluster(glyph)
