"""unit_defs/defense.luau `rampart` (BAR legrampart, Legion's Rampart): a geothermal powerplant on a vent that is also
an anti-nuke and a carrier for two heavy drones, held to 100 triangles.

A fortified geothermal bunker in Legion's rounded,
chamfered style: a broad eight-sided armoured hull with sloped walls and glowing heat vents on its faces carries,
up front, a team-coloured six-sided stack wrapped round a glowing orange geothermal core; at the back left, the
interceptor silo, a sloped block with two missile-tube hatches; at the back right, a raised team-coloured landing
pad for the drones on a pedestal. The interceptor has no turret, so nothing moves.
"""

import math

from .shared import common
from .shared import defense_b as d
from .shared import palette

CATEGORY = "entity"
DEF = "rampart"


def generate(params):
    w, l = params["collider"]["width"], params["collider"]["length"]
    objects = []

    # the armoured hull: eight-sided, walls sloping in, filling the footprint
    hull_h = 2.6
    top = 6.6
    objects.append(common.body_mat(d.block("hull", w, l, hull_h, top=(top, top), chamfer=1.8)))

    # heat vents glowing on the front and side walls
    slope = (w - top) / 2.0 / hull_h
    for a_deg in (270.0, 0.0, 180.0):
        a = math.radians(a_deg)
        n = (math.cos(a), math.sin(a))
        along = (-n[1] * 1.0, n[0] * 1.0, 0.0)
        mid = (w + top) / 4.0 + 0.03
        up = (-n[0] * slope * 0.25, -n[1] * slope * 0.25, 0.25)
        objects.append(common.glow_mat(d.panel("vent", (n[0] * mid, n[1] * mid, hull_h * 0.5), along, up), palette.GEOTHERMAL_CORE))

    # the core stack up front: a team-coloured hexagonal collar, open at the top, round the glowing core
    cy = -0.9
    stack_h = 1.6
    objects.append(common.accent_mat(d.prism("stack", 2.0, stack_h, 6, radius2=1.6, origin=(0.0, cy, hull_h), cap_top=False), params["color"]))
    objects.append(common.glow_mat(d.prism("core", 1.45, 2.6, 6, radius2=0.8, origin=(0.0, cy, hull_h + 0.4), cap_top=True), palette.GEOTHERMAL_CORE))

    # the interceptor silo at the back left: a sloped block with two tube hatches on its top
    sx, sy = -1.85, 1.85
    silo_h = 1.5
    objects.append(common.body_mat(d.block("silo", 1.8, 1.8, silo_h, origin=(sx, sy, hull_h), top=(1.5, 1.5))))
    for oy in (-0.37, 0.37):
        objects.append(common.trim_mat(d.disc("tube", 0.34, 6, origin=(sx, sy + oy, hull_h + silo_h + 0.02))))

    # the drone pad at the back right, raised on a pedestal
    px, py = 1.85, 1.75
    ped_h = 1.5
    objects.append(common.trim_mat(d.block("pedestal", 1.1, 1.1, ped_h, origin=(px, py, hull_h), cap_top=False)))
    pad_z = hull_h + ped_h
    objects.append(common.accent_mat(d.block("pad", 2.6, 2.6, 0.25, origin=(px, py, pad_z), top=(2.4, 2.4), cap_bottom=True), params["color"]))
    objects.append(common.glow_mat(d.panel("pad_mark", (px, py, pad_z + 0.26), (0.5, 0.0, 0.0), (0.0, 0.5, 0.0)), palette.GEOTHERMAL_CORE))

    return objects
