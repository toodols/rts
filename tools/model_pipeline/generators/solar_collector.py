"""unit_defs `solar_collector` (corsolar): 2x2x2 cells (8x8x8 studs), gold accent. Budget: 100 triangles.

Cortex's solar collector is a squat hub with four big photovoltaic petals opened around it. Here: a dark chamfered
deck, a gunmetal hexagonal collector hub with a gold cap and a glowing receiver on top, and four trapezoid
petals hinged off the hub and opening up and out over the deck's edges, each a gold frame carrying a deep blue
cell face. Nothing moves.
"""

import math

from . import economy_common as eco


def generate(params):
    w = float(params.get("width", 8.0))
    s = w / 8.0
    objects = []

    deck = eco.Mesh().frustum(eco.chamfered_rect(7.9 * s, 7.9 * s, 1.4 * s), eco.chamfered_rect(7.1 * s, 7.1 * s, 1.1 * s), 0.0, 0.7 * s)
    objects.append(eco.trim(deck.build("deck")))
    deck_top = 0.7 * s

    hub_top = deck_top + 2.0 * s
    hub = eco.Mesh().frustum(eco.ngon(1.45 * s, 6), eco.ngon(1.05 * s, 6), deck_top, hub_top, cap_top=False)
    objects.append(eco.body(hub.build("hub")))
    cap = eco.Mesh().pyramid(eco.at(eco.ngon(1.15 * s, 6), hub_top), (0.0, 0.0, hub_top + 0.8 * s), cap=True)
    objects.append(eco.accent(cap.build("hub_cap"), "solar", eco.GOLD))
    # glowing receiver: a diamond above the cap
    gz = hub_top + 1.35 * s
    r = 0.32 * s
    gem = eco.Mesh()
    ring = eco.at(eco.ngon(r, 4), gz)
    gem.pyramid(ring, (0.0, 0.0, gz + r * 1.4))
    gem.pyramid(list(reversed(ring)), (0.0, 0.0, gz - r * 1.4))
    objects.append(eco.glow(gem.build("receiver"), "solar", eco.SOLAR_GLOW, emission=0.9))

    # Four petals, hinged on the hub and opening up and out.
    tilt = math.radians(24.0)
    hinge_r = 1.05 * s
    hinge_z = deck_top + 1.2 * s
    length = 3.1 * s
    iw, ow, t = 2.0 * s, 4.7 * s, 0.18 * s
    trap = [(-iw / 2, 0.0), (iw / 2, 0.0), (ow / 2, length), (-ow / 2, length)]
    m_ = 0.2 * s
    inner = [(-iw / 2 + m_, m_), (iw / 2 - m_, m_), (ow / 2 - m_, length - m_), (-ow / 2 + m_, length - m_)]
    frames, cells = eco.Mesh(), eco.Mesh()
    for i in range(4):
        a = math.radians(90.0 * i)
        m = eco.matrix((math.cos(a) * hinge_r, math.sin(a) * hinge_r, hinge_z), (tilt, 0.0, a - math.pi / 2))
        # skip side 0, the hinge edge buried in the hub
        frames.frustum(trap, trap, 0.0, t, m=m, cap_bottom=True, skip=(0,))
        cells.poly(eco.at(inner, t + 0.01 * s), m=m)
    objects.append(eco.accent(frames.build("petal_frames"), "solar", eco.GOLD))
    objects.append(eco.cell(cells.build("petal_cells")))

    return objects
