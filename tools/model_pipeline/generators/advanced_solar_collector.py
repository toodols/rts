"""unit_defs `advanced_solar_collector` (coradvsol): gold accent. Budget: 100
triangles.

Where the plain collector is a light flower of petals on a hub, Cortex's advanced one is an armored box that
opens: a heavy gunmetal block whose flat roof is one big deep blue cell, with four thick gold armor shutters
swung open from the roof's edges (their inner faces lined with more cells, as reflectors), and dark pylons
with glowing tips standing at the corners between them. Nothing moves.
"""

import math

from .shared import common
from .shared import economy as eco
from .shared import palette

CATEGORY = "entity"
DEF = "advanced_solar_collector"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"width": 8.5, "length": 8.5}


def generate(params):
    accent = params["color"]
    w = params["collider"]["width"]
    s = w / 8.0
    objects = []

    block_h = 2.1 * s
    block = common.Faces().frustum(common.rect(7.9 * s, 7.9 * s), common.rect(6.7 * s, 6.7 * s), 0.0, block_h)
    objects.append(common.body_mat(block.build("block")))

    cells = common.Faces().polygon(common.at(common.rect(5.4 * s, 5.4 * s), block_h + 0.02 * s))

    # Four armor shutters swung open from the roof edges.
    hinge_r = 2.85 * s
    tilt = math.radians(27.0)
    sw, sl, st = 4.8 * s, 2.6 * s, 0.35 * s
    bottom = [(-sw / 2, 0.0), (sw / 2, 0.0), (sw / 2, st), (-sw / 2, st)]
    tw = sw * 0.84
    top = [(-tw / 2, 0.0), (tw / 2, 0.0), (tw / 2, st * 0.7), (-tw / 2, st * 0.7)]
    shutters = common.Faces()
    for i in range(4):
        a = math.radians(90.0 * i)
        m = eco.matrix((math.cos(a) * hinge_r, math.sin(a) * hinge_r, block_h - 0.1 * s), (-tilt, 0.0, a - math.pi / 2))
        # side 0 is the inner face, covered by the cells
        shutters.frustum(bottom, top, 0.0, sl, matrix=m, skip=(0,))
        cells.polygon([(-sw / 2, -0.01 * s, 0.0), (sw / 2, -0.01 * s, 0.0), (tw / 2, -0.01 * s, sl), (-tw / 2, -0.01 * s, sl)], matrix=m)
    objects.append(common.accent_mat(shutters.build("shutters"), accent))
    objects.append(eco.cell(cells.build("cells")))

    # Corner pylons between the shutters, with glowing tips.
    pylons, tips = common.Faces(), common.Faces()
    for i in range(4):
        a = math.radians(45.0 + 90.0 * i)
        d = 3.45 * s
        xy = (math.cos(a) * d, math.sin(a) * d)
        z1 = block_h + 1.7 * s
        pylons.frustum(common.ngon(4, 0.62 * s, a, xy), common.ngon(4, 0.4 * s, a, xy), block_h - 0.3 * s, z1, cap_top=False)
        tips.pyramid(common.at(common.ngon(4, 0.4 * s, a, xy), z1), (xy[0], xy[1], z1 + 0.7 * s))
    objects.append(common.trim_mat(pylons.build("pylons")))
    objects.append(common.glow_mat(tips.build("pylon_tips"), palette.SOLAR_GLOW))

    return objects
