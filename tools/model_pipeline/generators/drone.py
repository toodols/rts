"""unit_defs/vehicle_t2.luau `drone` (BAR's legdrone): the Mantis's small, quick combat drone.

A pointed team-colour fuselage with a dark wing through it, a lift rotor spinning in a nacelle at each wingtip,
a short laser under the nose and a glowing sensor eye. Its origin is the bottom of its collider, like any
unit's, though it flies. Collider capsule(20, 20, 20): radius 0.909, height 1.82 studs. 100-triangle budget.
"""

from . import common
from . import vehicle_t2_common as v

ACCENT = v.rgb(226, 226, 120)
EYE_COLOR = (1.0, 0.35, 0.25, 1.0)  # a hostile red eye, the laser's colour


def generate(params):
    radius, height = v.collider(20, 20, 20)
    m = v.Mats("drone", tuple(params.get("accent_color", ACCENT)))
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
    wing = v.block("wing", 1.0, 0.34, 0.07, origin=(0.0, 0.08, z + 0.16), top=(1.0, 0.26), top_offset=(0.0, 0.03),
                   drop=())
    objects.append(m.trim(wing))
    nx = 0.56
    for side in (-1, 1):
        nacelle = v.block(f"nacelle_{side}", 0.16, 0.4, 0.26, origin=(side * nx, 0.08, z + 0.06), top=(0.12, 0.3),
                          drop=())
        objects.append(m.body(nacelle))

    # Laser under the nose (10 tris) and the sensor eye on it (2).
    gun, tip = v.rod("laser", 0.04, 0.42, (0.0, -0.18, z + 0.04))
    objects.append(m.trim(gun))
    eye = v.decal("eye", [(-0.05, -0.47, z + 0.3), (0.05, -0.47, z + 0.3), (0.08, -0.3, z + 0.345),
                          (-0.08, -0.3, z + 0.345)], up=(0.0, -0.3, 1.0))
    objects.append(m.glow(eye, color=EYE_COLOR, name="eye"))

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

    v.check_fit(objects, radius, height, "drone")
    return objects
