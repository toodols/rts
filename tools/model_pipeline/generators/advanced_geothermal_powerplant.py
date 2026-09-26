"""unit_defs `advanced_geothermal_powerplant` (corageo): hazard orange accent. Budget:
100 triangles.

The plain geothermal plant's big brother, built over the same vent but filling its whole box: a heavy armoured
plinth, and on it a tall three-stage heat stack -- an orange armoured skirt, a band of exposed white-hot core, and
a dark chimney capped with glowing heat -- ringed by four squat cooling towers at the corners, each venting glow
from its open throat. It reads as dangerous machinery rather than the fusion reactor's contained orb on spikes.
Nothing moves.
"""

import math

from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "advanced_geothermal_powerplant"


def generate(params):
    accent = params["color"]
    w = params["collider"]["width"]
    s = w / 8.0
    objects = []

    # Armoured plinth over the vent.
    plinth_h = 1.3 * s
    plinth = common.Faces().frustum(common.rect(7.9 * s, 7.9 * s), common.rect(7.0 * s, 7.0 * s), 0.0, plinth_h)
    objects.append(common.body_mat(plinth.build("plinth")))

    glow = common.Faces()

    # Heat stack: orange armour skirt, exposed glowing core band, dark chimney with a glowing mouth.
    rot = math.radians(30.0)
    skirt_top = 3.4 * s
    band_top = 4.7 * s
    stack_top = 7.7 * s
    skirt = common.Faces().frustum(common.ngon(6, 2.15 * s, rot), common.ngon(6, 1.55 * s, rot), plinth_h, skirt_top)
    objects.append(common.accent_mat(skirt.build("stack_skirt"), accent))
    glow.frustum(common.ngon(6, 1.4 * s, rot), common.ngon(6, 1.4 * s, rot), skirt_top, band_top, cap_top=False)
    chimney = common.Faces().frustum(common.ngon(6, 1.6 * s, rot), common.ngon(6, 1.15 * s, rot), band_top, stack_top, cap_top=False)
    objects.append(common.trim_mat(chimney.build("stack_chimney")))
    glow.polygon(common.at(common.ngon(6, 1.15 * s, rot), stack_top))

    # Four cooling towers at the corners, venting heat.
    towers = common.Faces()
    tower_top = 4.4 * s
    for sx in (-1.0, 1.0):
        for sy in (-1.0, 1.0):
            xy = (sx * 2.45 * s, sy * 2.45 * s)
            towers.frustum(common.rect(1.8 * s, 1.8 * s, xy), common.rect(1.3 * s, 1.3 * s, xy), plinth_h, tower_top, cap_top=False)
            glow.polygon(common.at(common.rect(1.3 * s, 1.3 * s, xy), tower_top - 0.05 * s))
    objects.append(common.accent_mat(towers.build("cooling_towers"), accent))

    objects.append(common.glow_mat(glow.build("heat_glow"), palette.DEEP_VENT_HEAT))
    return objects
