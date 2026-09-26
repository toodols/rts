"""unit_defs/factory.luau `vehicle_lab` (BAR corvp): a factory for T1 vehicles.

Low and wide where the bot lab is tall and narrow: a broad open vehicle bay between two low armoured side walls,
a sloped control block across the back, and two tall yellow nanolathe cranes rising from the side walls and
leaning in over the front edge, where production.luau builds each unit (Blender -Y, Roblox +Z). The cranes'
elbows poke a little above the 4-stud box. Under 100 triangles.
"""

from .shared import common
from .shared import factory as fc

CATEGORY = "entity"
DEF = "vehicle_lab"
# built reaching past its collider before the build held it to one: refitting it means re-uploading its meshes
ENVELOPE = {"height": 4.86}


def generate(params):
    hw, hl = params["collider"]["width"] / 2, params["collider"]["length"] / 2
    body, accent, nano, glow = fc.Shape(), fc.Shape(), fc.Shape(), fc.Shape()
    floor = 0.45
    bay = 3.8
    front = -5.8
    wall_top = 2.3
    glacis_top = -4.3

    footing = fc.Shape().hull((-hw, hw, -hl, hl), (-5.8, 5.8, -5.8, 5.8), 0.0, floor)

    for sx in (-1, 1):
        inner, outer, outer_top = sx * bay, sx * 6.0, sx * 5.3
        body.hull((min(inner, outer), max(inner, outer), front, 5.8),
                  (min(inner, outer_top), max(inner, outer_top), glacis_top, 5.8), floor, wall_top)
        # Team panel along the wall top, and a team guide rail on the bay floor.
        a, b = sx * (bay + 0.2), sx * 5.1
        accent.quad((a, glacis_top + 0.2, wall_top + 0.03), (b, glacis_top + 0.2, wall_top + 0.03),
                    (b, 5.5, wall_top + 0.03), (a, 5.5, wall_top + 0.03), normal=(0, 0, 1))
        r0, r1 = sx * (bay - 0.9), sx * (bay - 0.5)
        accent.quad((r0, front, floor + 0.02), (r1, front, floor + 0.02), (r1, 2.8, floor + 0.02), (r0, 2.8, floor + 0.02),
                    normal=(0, 0, 1))
        # Crane: a mast out of the wall top, bending over the bay toward the build spot.
        fc.nano_arm(nano, glow, [(sx * 4.6, -2.8, wall_top - 0.3), (sx * 4.4, -3.4, 4.6)], (sx * 0.8, -8.6, 0.6),
                    w=0.55, reach=2.4, glow_len=0.75)

    # Control block across the back, its front face sloped.
    body.hull((-bay, bay, 2.8, 5.8), (-bay, bay, 4.0, 5.8), floor, 3.8)
    accent.quad((-bay + 0.4, 4.2, 3.83), (bay - 0.4, 4.2, 3.83), (bay - 0.4, 5.5, 3.83), (-bay + 0.4, 5.5, 3.83), normal=(0, 0, 1))
    fc.chevron(nano, 0.0, front - 0.1, floor + 0.02, 4.0, 0.7)
    fc.chevron(nano, 0.0, front + 1.5, floor + 0.02, 4.0, 0.7)

    objs = [
        common.trim_mat(footing.build("footing")),
        common.body_mat(body.build("body")),
        common.accent_mat(accent.build("accent"), params["color"]),
        common.hivis_mat(nano.build("nano")),
        common.nano_mat(glow.build("glow")),
    ]
    return objs
