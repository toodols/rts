"""unit_defs/factory.luau `seaplane_platform` (BAR corplat): a factory for seaplanes.

It floats, as the shipyards do: z = 0 here is the waterline. Unlike their U-shaped docks it is a raft: two long
pontoons with raked bows carrying a flat deck between them, marked with a team-coloured landing circle, whose front
runs down into the water as a slipway with yellow hazard stripes, where production.luau builds each seaplane (Blender
-Y, Roblox +Z). A control tower on stilts stands on the right pontoon's stern with a lit cab and a radar paddle that
spins, and a team-coloured crane post stands on the left; each carries a yellow nanolathe arm leaning out over the
slipway. Under 100 triangles.
"""

from .shared import air_t1 as air
from .shared import common
from .shared import factory as fc

CATEGORY = "entity"
DEF = "seaplane_platform"


def generate(params):
    hw, hl = params["collider"]["width"] / 2, params["collider"]["length"] / 2
    raft, body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    keel, deck = -0.6, 0.7
    front = -1.5

    # Two pontoons with raked bows, their hulls dipping below the waterline.
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 4.3, sx * 5.8))
        t0, t1 = sorted((sx * 4.2, sx * hw))
        raft.hull((x0, x1, -hl + 1.2, hl - 0.4), (t0, t1, -hl, hl), keel, deck)
    # The deck between them, and the slipway running from its front edge down into the water.
    raft.box(-4.2, 4.2, front, hl - 0.2, deck - 0.5, deck, drop=("bottom", "left", "right"))
    slip_y = -hl + 0.4
    raft.quad((-4.2, slip_y, -0.3), (4.2, slip_y, -0.3), (4.2, front, deck), (-4.2, front, deck), normal=(0, -0.3, 1))
    # Hazard stripes down either side of the slipway.
    slope = (deck + 0.3) / (front - slip_y)
    zs = lambda y: -0.3 + (y - slip_y) * slope + 0.03
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 3.3, sx * 3.9))
        nano.quad((x0, slip_y + 0.3, zs(slip_y + 0.3)), (x1, slip_y + 0.3, zs(slip_y + 0.3)),
                  (x1, front - 0.1, zs(front - 0.1)), (x0, front - 0.1, zs(front - 0.1)), normal=(0, -slope, 1))

    # The landing circle on the deck.
    z = deck + 0.02
    ring = accent._add(common.at(common.ngon(8, 2.6, 0.0, (0.0, 2.2)), z))
    accent._face([ring + i for i in range(8)], normal=(0, 0, 1))

    # The control tower: a tapering pylon on the right pontoon's stern, and a cab on top with a lit front.
    body.hull((4.3, 5.8, 3.4, 5.4), (4.7, 5.5, 3.9, 5.0), deck, 2.9, drop=("bottom", "top"))
    cab_top = 3.55
    body.hull((4.0, 5.95, 3.1, 5.7), (4.2, 5.8, 3.3, 5.6), 2.9, cab_top)
    glow.quad((4.1, 3.14, 3.05), (5.9, 3.14, 3.05), (5.75, 3.29, 3.40), (4.25, 3.29, 3.40), normal=(0, -1, 0.4))
    fc.nano_arm(nano, glow, [(4.9, 3.6, 2.6)], (0.6, -8.4, 0.5), w=0.4, reach=2.2, glow_len=0.6)

    # The crane post on the left pontoon, its nanolathe leaning out over the slipway.
    accent.hull((-5.7, -4.4, 3.6, 5.0), (-5.35, -4.75, 4.0, 4.6), deck, 3.2)
    fc.nano_arm(nano, glow, [(-5.05, 4.3, 2.9)], (-0.6, -8.4, 0.5), w=0.4, reach=2.2, glow_len=0.6)

    objs = [
        common.body_mat(raft.build("raft")),
        common.body_mat(body.build("body")),
        common.accent_mat(accent.build("accent"), params["color"]),
        common.hivis_mat(nano.build("nano")),
        common.nano_mat(glow.build("glow")),
    ]

    # The radar paddle on the cab's roof, spinning: a flat blade either way up so it shows from below as well.
    mast = (4.95, 4.35, cab_top + 0.05)
    blades = [air.plate(f"radar_{facing:+.0f}", (0.0, facing * 0.005, 0.2), (0.7, 0, 0), (0, 0, 0.18), (0, facing, 0))
              for facing in (1.0, -1.0)]
    radar = common.merge("radar", blades, origin=mast)
    common.trim_mat(radar)
    objs.append(common.art_group(radar, "radar", pivot=True, kind="spin", axis=(0.0, 0.0, 1.0), speed=1.5))
    return objs
