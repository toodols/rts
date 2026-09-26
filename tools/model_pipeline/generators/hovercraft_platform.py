"""unit_defs/factory.luau `hovercraft_platform` (BAR corhp): a factory for hovercraft.

Where the vehicle lab is a walled bay, this is an open launch apron: a broad, low pad with no walls or roof, its
front a long slipway sloping down to the ground on the open side where production.luau builds each hovercraft
(Blender -Y, Roblox +Z). Two tapered gantry towers flank the pad, joined high up by a team-coloured beam that
leaves the apron open beneath, each carrying a yellow nanolathe arm that leans in over the slipway. A low control
block sits across the back, and the deck carries a team-coloured hexagonal landing mark and yellow launch chevrons.
100 triangles.
"""

import math

from .shared import common
from .shared import factory as fc

CATEGORY = "entity"
DEF = "hovercraft_platform"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"height": 4.9}


def generate(params):
    hw, hl = params["collider"]["width"] / 2, params["collider"]["length"] / 2
    body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    base = 0.25
    deck = 0.9
    front = -hl
    ramp_top = -2.6
    tower_top = 4.9

    footing = fc.Shape().hull((-hw, hw, -hl, hl), (-5.85, 5.85, -5.85, 5.85), 0.0, base)

    # The pad: deck from the back to ramp_top, then a slipway down to the front edge.
    body.hull((-4.4, 4.4, front, 5.8), (-4.2, 4.2, ramp_top, 5.8), base, deck)

    for sx in (-1, 1):
        # Gantry tower beside the pad, tapering as it rises.
        x0, x1 = sorted((sx * 4.5, sx * 5.9))
        t0, t1 = sorted((sx * 4.8, sx * 5.4))
        body.hull((x0, x1, -2.4, 1.6), (t0, t1, -1.4, 0.4), base, tower_top)
        # Team stripe down the tower's inner face.
        xi = sx * 4.5 - sx * 0.03
        xt = sx * 4.8 - sx * 0.03
        zlo, zhi = 1.2, 3.6
        f = lambda z: (z - base) / (tower_top - base)
        xa, xb = xi + (xt - xi) * f(zlo), xi + (xt - xi) * f(zhi)
        ya0, ya1 = -2.4 + 1.0 * f(zlo), 1.6 - 1.2 * f(zlo)
        yb0, yb1 = -2.4 + 1.0 * f(zhi), 1.6 - 1.2 * f(zhi)
        accent.quad((xa, ya0 + 0.3, zlo), (xa, ya1 - 0.3, zlo), (xb, yb1 - 0.3, zhi), (xb, yb0 + 0.3, zhi),
                    normal=(-sx, 0, 0))
        # Nanolathe arm off the tower top, leaning in over the slipway toward the build spot.
        fc.nano_arm(nano, glow, [(sx * 5.0, -1.0, tower_top - 0.5)], (sx * 0.6, -8.4, 0.5), w=0.5, reach=3.4,
                    glow_len=0.7)

    # Team-coloured gantry beam spanning the pad between the tower tops, leaving it open beneath.
    accent.box(-4.85, 4.85, -0.4, 0.3, tower_top - 0.6, tower_top - 0.05, drop=("left", "right"))

    # Low control block across the back of the pad.
    body.hull((-3.6, 3.6, 3.6, 5.8), (-3.2, 3.2, 4.3, 5.7), deck, 2.2, drop=("bottom",))
    accent.quad((-2.8, 4.6, 2.23), (2.8, 4.6, 2.23), (2.8, 5.4, 2.23), (-2.8, 5.4, 2.23), normal=(0, 0, 1))

    # Landing diamond on the deck, and launch chevrons down the slipway.
    z = deck + 0.02
    # Team-coloured hexagonal landing mark on the deck.
    hexagon = accent._add([(2.4 * math.cos(math.pi * i / 3), 0.6 + 2.4 * math.sin(math.pi * i / 3), z)
                           for i in range(6)])
    accent._face([hexagon + i for i in range(6)], normal=(0, 0, 1))
    slope = (deck - base) / (ramp_top - front)
    zr = lambda y: base + (y - front) * slope + 0.04
    n = fc.V((0.0, -slope, 1.0)).normalized()
    for tip in (-5.8, -4.6):
        # A chevron laid on the slipway, pointing out toward the build spot.
        half, bar = 1.8, 0.6
        for sx in (-1.0, 1.0):
            pts = [(0.0, tip), (sx * half, tip + half * 0.8), (sx * half, tip + half * 0.8 + bar), (0.0, tip + bar)]
            nano.quad(*[(x, y, zr(y)) for x, y in pts], normal=tuple(n))

    objs = [
        common.trim_mat(footing.build("footing")),
        common.body_mat(body.build("body")),
        common.accent_mat(accent.build("accent"), params["color"]),
        common.hivis_mat(nano.build("nano")),
        common.nano_mat(glow.build("glow")),
    ]
    return objs
