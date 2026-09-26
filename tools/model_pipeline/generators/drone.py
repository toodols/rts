"""unit_defs/vehicle_t2.luau `drone` (BAR's legdrone): the Mantis's small, quick combat drone.

A pointed team-colour fuselage with a dark wing through it, a lift rotor spinning in a nacelle at each wingtip,
a short laser under the nose and a glowing sensor eye. Its origin is the bottom of its collider, like any
unit's, though it flies."""

from .shared import common
from .shared import palette
from .shared import vehicle_t2 as v

CATEGORY = "entity"
DEF = "drone"


def generate(params):
    m = common.Materials(params["color"], palette.HEADLIGHT)
    objects = []
    z = 0.62  # belly height

    # Footprint first: the team-colour fuselage, pointed forward, closed underneath (it is seen from below too) (20 tris).
    body = v.loft("fuselage", [
        (-0.62, 0.05, 0.04, z + 0.16, z + 0.24),
        (-0.18, 0.2, 0.16, z, z + 0.36),
        (0.62, 0.12, 0.08, z + 0.1, z + 0.28),
    ], drop=())
    objects.append(m.accent(body))

    # Wing through the fuselage (12 tris) and a nacelle at each tip (10 each).
    wing = common.block("wing", 1.0, 0.34, 0.07, top=(1.0, 0.26), top_offset=(0.0, 0.03), at=(0.0, 0.08, z + 0.16), drop=())
    objects.append(m.trim(wing))
    nx = 0.56
    for side in (-1, 1):
        nacelle = common.block(f"nacelle_{side}", 0.16, 0.4, 0.26, top=(0.12, 0.3), at=(side * nx, 0.08, z + 0.06), drop=())
        objects.append(m.body(nacelle))

    # Laser under the nose (10 tris) and the sensor eye on it (2).
    gun, tip = v.rod("laser", 0.04, 0.42, (0.0, -0.18, z + 0.04))
    objects.append(m.trim(gun))
    eye = v.decal("eye", [(-0.05, -0.47, z + 0.3), (0.05, -0.47, z + 0.3), (0.08, -0.3, z + 0.345),
                          (-0.08, -0.3, z + 0.345)], up=(0.0, -0.3, 1.0))
    objects.append(m.glow(eye, palette.HOSTILE_RED))

    # Two-bladed rotors over the nacelles, each spinning on its own (4 tris: top and underside).
    for side in (-1, 1):
        rz = z + 0.34
        blade = v.mesh(f"blade_{side}", [(-0.32, -0.05, 0.0), (0.32, -0.05, 0.0), (0.32, 0.05, 0.0),
                                         (-0.32, 0.05, 0.0)], [(0, 1, 2, 3)], up=(0.0, 0.0, 1.0))
        under = v.mesh(f"blade_under_{side}", [(-0.32, -0.05, -0.005), (0.32, -0.05, -0.005),
                                               (0.32, 0.05, -0.005), (-0.32, 0.05, -0.005)], [(0, 1, 2, 3)],
                       up=(0.0, 0.0, -1.0))
        hub, _ = v.rod(f"hub_{side}", 0.04, 0.08, (0.0, 0.0, -0.08), pitch=90.0, sides=3, front_cap=False)
        for p in (blade, under, hub):
            m.trim(p)
        rotor = common.merge(f"rotor_{side}", [blade, under, hub], origin=(side * nx, 0.08, rz))
        rotor.rotation_euler = (0.0, 0.0, 0.5 if side > 0 else -0.5)
        objects.append(common.art_group(rotor, f"rotor_{'r' if side > 0 else 'l'}", pivot=True, kind="spin",
                                        axis=(0.0, 0.0, 1.0), speed=-30.0 * side))

    return objects
