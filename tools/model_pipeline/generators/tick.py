"""unit_defs/bot_t1.luau `tick` (armflea): a tiny, quick scout bot with a short-range laser.

A four-legged spider no taller than a Grunt's knee: a low wedge body with a team-coloured shell,
a single laser eye poking out the front, and four high-kneed legs splayed to the diagonals. The body
turns as weapon 1's turret; each leg sweeps about its root as it walks.

Budget: 100 triangles.
"""

import math

from .shared import bot_t1 as bt
from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "tick"
# its legs sweep about the vertical as it walks, carrying its splayed feet past the corners of its footprint
ENVELOPE = {"width": 2.04, "length": 1.95}
MOUNTS = {
    1: {"pivot": (0, 0, 0), "muzzle": (0, 0.5783, 0.9091)},
}


def generate(params):
    accent = params["color"]
    m = common.Materials(accent, palette.SCOUT_EYE)

    upper = []
    body = m.body(bt.slab("body", 0.5, 0.64, 0.2, top_w=0.44, top_d=0.56, top_offset=(0.0, 0.02), origin=(0.0, 0.0, 0.36)))
    upper.append(body)
    # the shell: a wedge rising toward the back, so it looks poised to pounce
    upper.append(m.accent(bt.hexa(
        "shell",
        [(-0.22, -0.26, 0.56), (0.22, -0.26, 0.56), (0.22, 0.3, 0.56), (-0.22, 0.3, 0.56)],
        [(-0.12, -0.14, 0.66), (0.12, -0.14, 0.66), (0.14, 0.22, 0.76), (-0.14, 0.22, 0.76)],
    )))
    # laser eye under the nose
    upper.append(m.trim(bt.beam("laser", (0.0, -0.22, 0.46), (0.0, -0.62, 0.46), 0.14, 0.14, 0.08, 0.08, caps="t")))
    upper.append(m.glow(bt.pyramid("eye", (0.0, -0.62, 0.46), 0.1, 0.1, (0.0, -0.7, 0.46))))

    legs = []
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            # front legs reach forward, back legs back, all splayed out
            a = math.radians(90.0 - (40.0 if sy < 0 else 50.0))
            dx, dy = sx * math.sin(a), sy * math.cos(a)
            hip = (sx * 0.2, sy * 0.2, 0.44)
            knee = (dx * 0.56, dy * 0.56, 0.8)
            foot = (dx * 0.86, dy * 0.86, 0.02)
            tag = f"{'l' if sx < 0 else 'r'}{'f' if sy < 0 else 'b'}"
            leg = bt.limb(f"leg_{tag}", [hip, knee, foot], [(0.11, 0.12), (0.1, 0.12)], tip=True)
            # each leg sweeps about the vertical through its root; diagonal pairs move together
            phase = 0.0 if tag in ("lf", "rb") else 0.5
            reach = math.hypot(foot[0] - hip[0], foot[1] - hip[1])
            legs.append(bt.walking_leg(f"leg_{tag}", [leg], hip, m.trim, phase, 0.3, axis=(0.0, 0.0, 1.0), stride=4.0 * reach * math.sin(0.3)))

    bt.group(upper, "torso", body, kind="turret", weapon=1)
    objs = upper + legs
    return objs
