"""unit_defs/factory.luau `advanced_shipyard` (BAR corasy): a 4x2x4 cell (16 x 8 x 16 stud) ship factory for the
second tier.

It floats, as the shipyard does: z = 0 here is the waterline. The shipyard's U-shaped dock grown into a heavier one --
two long armoured pontoons with raked bows, each with a raised bulwark along its outer edge, joined by a deep stern
block -- open to the front, where production.luau builds each ship (Blender -Y, Roblox +Z). Two team-coloured gantry
cranes straddle the slip, each with a pair of yellow nanolathes aimed out past the bows, and a stepped command tower
with a lit bridge and a mast stands on the stern block. Under 200 triangles. It is laid out 12 studs square and
stretched to its 16 along the level.
"""

from . import factory_common as fc

# From the 12 studs it is laid out in to the 16 its footprint is.
SPREAD = 16.0 / 12.0


def generate(params):
    k = fc.Kit("advshipyard")
    trim, body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    keel, deck = -0.9, 1.0

    dock = fc.Shape()
    for sx in (-1, 1):
        x0, x1 = sorted((sx * 6.0, sx * 3.4))
        t0, t1 = sorted((sx * 5.7, sx * 3.5))
        dock.hull((x0, x1, -6.0, 6.0), (t0, t1, -5.0, 5.9), keel, deck)
        # A bulwark along each pontoon's outer edge.
        b0, b1 = sorted((sx * 5.6, sx * 5.0))
        trim.hull((b0, b1, -4.4, 5.8), (b0, b1, -4.0, 5.8), deck, deck + 0.6, drop=("bottom", "back"))
        # Yellow hazard plates on the bows.
        nano.quad((t0 + 0.2, -4.9, deck + 0.02), (t1 - 0.2, -4.9, deck + 0.02), (t1 - 0.2, -4.1, deck + 0.02),
                  (t0 + 0.2, -4.1, deck + 0.02), normal=(0, 0, 1))
    # Stern block joining the pontoons.
    dock.hull((-3.4, 3.4, 3.4, 6.0), (-3.5, 3.5, 3.6, 5.9), keel, deck, drop=("bottom", "left", "right"))

    # Stepped command tower on the stern block, with a lit bridge window on its raked front and a mast on top.
    top = 5.0
    body.hull((-2.6, 2.6, 3.5, 5.95), (-2.2, 2.2, 4.0, 5.85), deck, top)
    bridge = 6.6
    body.hull((-1.7, 1.7, 4.2, 5.7), (-1.4, 1.4, 4.9, 5.6), top, bridge, drop=("bottom",))
    n = fc.V((0.0, -(bridge - top), 0.7)).normalized() * 0.03
    y_at = lambda z: 4.2 + 0.7 * (z - top) / (bridge - top)
    glow.quad(fc.V((-1.5, y_at(5.6), 5.6)) + n, fc.V((1.5, y_at(5.6), 5.6)) + n, fc.V((1.45, y_at(6.3), 6.3)) + n,
              fc.V((-1.45, y_at(6.3), 6.3)) + n, normal=n)
    trim.box(-0.15, 0.15, 5.0, 5.3, bridge, 8.4)
    accent.box(-0.9, 0.9, 5.05, 5.25, 7.8, 8.05)

    # Two gantry cranes straddling the slip: legs on the pontoons, a beam across, two nanolathes hanging from each.
    for y_mid in (-2.8, 0.6):
        for sx in (-1, 1):
            x0, x1 = sorted((sx * 3.55, sx * 5.2))
            t0, t1 = sorted((sx * 3.9, sx * 4.8))
            accent.hull((x0, x1, y_mid - 0.7, y_mid + 0.7), (t0, t1, y_mid - 0.4, y_mid + 0.4), deck, 6.2,
                        drop=("bottom", "top"))
        accent.box(-5.1, 5.1, y_mid - 0.55, y_mid + 0.55, 6.2, 6.9)
        for sx in (-1, 1):
            fc.nano_arm(nano, glow, [(sx * 1.8, y_mid, 6.55)], (sx * 0.4, -10.0, 0.3), w=0.5, reach=2.0,
                        glow_len=0.6)

    objs = [
        k.body(dock.build("dock")),
        k.body(body.build("body")),
        k.trim(trim.build("trim")),
        k.accent(accent.build("accent")),
        k.nano(nano.build("nano")),
        k.glow(glow.build("glow")),
    ]
    for obj in objs:
        for v in obj.data.vertices:
            v.co.x *= SPREAD
            v.co.y *= SPREAD
    return fc.finish(objs)
