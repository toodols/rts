"""unit_defs `advanced_solar_collector` (coradvsol): 2x2x2 cells (8x8x8 studs), gold accent. Budget: 100
triangles.

Where the plain collector is a light flower of petals on a hub, Cortex's advanced one is an armored box that
opens: a heavy gunmetal block whose flat roof is one big deep blue cell, with four thick gold armor shutters
swung open from the roof's edges (their inner faces lined with more cells, as reflectors), and dark pylons
with glowing tips standing at the corners between them. Nothing moves.
"""

import math

from . import economy_common as eco


def generate(params):
    w = float(params.get("width", 8.0))
    s = w / 8.0
    objects = []

    block_h = 2.1 * s
    block = eco.Mesh().frustum(eco.rect(7.9 * s, 7.9 * s), eco.rect(6.7 * s, 6.7 * s), 0.0, block_h)
    objects.append(eco.body(block.build("block")))

    cells = eco.Mesh().poly(eco.at(eco.rect(5.4 * s, 5.4 * s), block_h + 0.02 * s))

    # Four armor shutters swung open from the roof edges.
    hinge_r = 2.85 * s
    tilt = math.radians(27.0)
    sw, sl, st = 4.8 * s, 2.6 * s, 0.35 * s
    bottom = [(-sw / 2, 0.0), (sw / 2, 0.0), (sw / 2, st), (-sw / 2, st)]
    tw = sw * 0.84
    top = [(-tw / 2, 0.0), (tw / 2, 0.0), (tw / 2, st * 0.7), (-tw / 2, st * 0.7)]
    shutters = eco.Mesh()
    for i in range(4):
        a = math.radians(90.0 * i)
        m = eco.matrix((math.cos(a) * hinge_r, math.sin(a) * hinge_r, block_h - 0.1 * s), (-tilt, 0.0, a - math.pi / 2))
        # side 0 is the inner face, covered by the cells
        shutters.frustum(bottom, top, 0.0, sl, m=m, skip=(0,))
        cells.poly([(-sw / 2, -0.01 * s, 0.0), (sw / 2, -0.01 * s, 0.0), (tw / 2, -0.01 * s, sl), (-tw / 2, -0.01 * s, sl)], m=m)
    objects.append(eco.accent(shutters.build("shutters"), "adv_solar", eco.GOLD))
    objects.append(eco.cell(cells.build("cells")))

    # Corner pylons between the shutters, with glowing tips.
    pylons, tips = eco.Mesh(), eco.Mesh()
    for i in range(4):
        a = math.radians(45.0 + 90.0 * i)
        d = 3.45 * s
        xy = (math.cos(a) * d, math.sin(a) * d)
        z1 = block_h + 1.7 * s
        pylons.frustum(eco.ngon(0.62 * s, 4, a, xy), eco.ngon(0.4 * s, 4, a, xy), block_h - 0.3 * s, z1, cap_top=False)
        tips.pyramid(eco.at(eco.ngon(0.4 * s, 4, a, xy), z1), (xy[0], xy[1], z1 + 0.7 * s))
    objects.append(eco.trim(pylons.build("pylons")))
    objects.append(eco.glow(tips.build("pylon_tips"), "adv_solar", eco.SOLAR_GLOW, emission=0.9))

    return objects
