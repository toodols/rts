"""unit_defs/factory.luau `shipyard` (BAR corsy): a ship factory.

It floats (it has a min_water_depth, so unit_defs.surface_height rests its underside on the water's surface):
z = 0 here is the waterline. A U-shaped floating dock -- two pontoons with raked bows joined by a stern block,
their hulls dipping below the waterline -- open to the front, where production.luau builds each ship
(Blender -Y, Roblox +Z). A team-coloured gantry crane straddles the slip with two yellow nanolathes hanging from
it aimed out past the bows, and a control tower stands on the stern block. Under 100 triangles.
"""

from .shared import common
from .shared import factory as fc

CATEGORY = "entity"
DEF = "shipyard"


def generate(params):
    hw, hl = params["collider"]["width"] / 2, params["collider"]["length"] / 2
    body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    keel, deck = -0.6, 0.8

    dock = fc.Shape()
    for sx in (-1, 1):
        x0, x1 = sorted((sx * hw, sx * 2.3))
        t0, t1 = sorted((sx * 3.8, sx * 2.4))
        dock.hull((x0, x1, -hl, hl), (t0, t1, -3.3, 3.9), keel, deck)
        # Yellow hazard plates on the bows.
        nano.quad((t0 + 0.2, -3.2, deck + 0.02), (t1 - 0.2, -3.2, deck + 0.02), (t1 - 0.2, -2.5, deck + 0.02),
                  (t0 + 0.2, -2.5, deck + 0.02), normal=(0, 0, 1))
    # Stern block joining the pontoons.
    dock.hull((-2.3, 2.3, 2.3, hl), (-2.4, 2.4, 2.5, 3.9), keel, deck, drop=("bottom", "left", "right"))

    # Control tower on the stern block, with a lit window on its raked front.
    top = 5.2
    body.hull((-1.8, 1.8, 2.4, 3.95), (-1.4, 1.4, 3.1, 3.85), deck, top)
    n = fc.V((0.0, -(top - deck), 0.7)).normalized() * 0.03
    y_at = lambda z: 2.4 + 0.7 * (z - deck) / (top - deck)
    glow.quad(fc.V((-1.3, y_at(4.0), 4.0)) + n, fc.V((1.3, y_at(4.0), 4.0)) + n, fc.V((1.25, y_at(4.7), 4.7)) + n,
              fc.V((-1.25, y_at(4.7), 4.7)) + n, normal=n)

    # Gantry crane straddling the slip: legs on the pontoons, a beam across.
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 2.45, sx * 3.75))
        t0, t1 = sorted((sx * 2.75, sx * 3.35))
        accent.hull((x0, x1, -2.1, -0.7), (t0, t1, -1.8, -1.0), deck, 5.4, drop=("bottom", "top"))
    accent.box(-3.6, 3.6, -1.95, -0.85, 5.4, 6.1)
    for sx in (-1, 1):
        fc.nano_arm(nano, glow, [(sx * 1.3, -1.4, 5.75)], (sx * 0.3, -7.0, 0.3), w=0.45, reach=1.9, glow_len=0.6)

    objs = [
        common.body_mat(dock.build("dock")),
        common.body_mat(body.build("body")),
        common.accent_mat(accent.build("accent"), params["color"]),
        common.hivis_mat(nano.build("nano")),
        common.nano_mat(glow.build("glow")),
    ]
    return objs
