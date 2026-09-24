"""unit_defs `advanced_geothermal_powerplant` (corageo): 2x2x2 cells (8x8x8 studs), hazard orange accent. Budget:
100 triangles.

The plain geothermal plant's big brother, built over the same vent but filling its whole box: a heavy armoured
plinth, and on it a tall three-stage heat stack -- an orange armoured skirt, a band of exposed white-hot core, and
a dark chimney capped with glowing heat -- ringed by four squat cooling towers at the corners, each venting glow
from its open throat. It reads as dangerous machinery rather than the fusion reactor's contained orb on spikes.
Nothing moves.
"""

import math

from . import economy_common as eco

ACCENT = (0.839, 0.431, 0.243, 1.0)  # unit_defs Color3.fromRGB(214, 110, 62)
HEAT_GLOW = (1.0, 0.38, 0.10, 1.0)  # molten orange-red geothermal heat


def generate(params):
    w = float(params.get("width", 8.0))
    s = w / 8.0
    objects = []

    # Armoured plinth over the vent.
    plinth_h = 1.3 * s
    plinth = eco.Mesh().frustum(eco.rect(7.9 * s, 7.9 * s), eco.rect(7.0 * s, 7.0 * s), 0.0, plinth_h)
    objects.append(eco.body(plinth.build("plinth")))

    glow = eco.Mesh()

    # Heat stack: orange armour skirt, exposed glowing core band, dark chimney with a glowing mouth.
    rot = math.radians(30.0)
    skirt_top = 3.4 * s
    band_top = 4.7 * s
    stack_top = 7.7 * s
    skirt = eco.Mesh().frustum(eco.ngon(2.15 * s, 6, rot), eco.ngon(1.55 * s, 6, rot), plinth_h, skirt_top)
    objects.append(eco.accent(skirt.build("stack_skirt"), "adv_geo", ACCENT))
    glow.frustum(eco.ngon(1.4 * s, 6, rot), eco.ngon(1.4 * s, 6, rot), skirt_top, band_top, cap_top=False)
    chimney = eco.Mesh().frustum(eco.ngon(1.6 * s, 6, rot), eco.ngon(1.15 * s, 6, rot), band_top, stack_top, cap_top=False)
    objects.append(eco.trim(chimney.build("stack_chimney")))
    glow.poly(eco.at(eco.ngon(1.15 * s, 6, rot), stack_top))

    # Four cooling towers at the corners, venting heat.
    towers = eco.Mesh()
    tower_top = 4.4 * s
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            xy = (sx * 2.45 * s, sy * 2.45 * s)
            towers.frustum(eco.rect(1.8 * s, 1.8 * s, xy), eco.rect(1.3 * s, 1.3 * s, xy), plinth_h, tower_top, cap_top=False)
            glow.poly(eco.at(eco.rect(1.3 * s, 1.3 * s, xy), tower_top - 0.05 * s))
    objects.append(eco.accent(towers.build("cooling_towers"), "adv_geo", ACCENT))

    objects.append(eco.glow(glow.build("heat_glow"), "adv_geo", HEAT_GLOW, emission=1.4))
    return objects
