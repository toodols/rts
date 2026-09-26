"""Shared builders for the energy/metal storage buildings and their hardened upgrades, each filling its def's
footprint in its def's colour. Each is under 100 triangles:

- Energy storage is a capacitor: a gold hexagonal drum on a sloped plinth, ringed by glowing cells, with a dark
  cap and two terminals. The hardened one drops the terminals and a cell for four sloped armor slabs.
- Metal storage is a steel silo: a hexagonal tank with a hopper roof and a round vault door on the front
  (Blender -Y, Roblox +Z).
- Hardened metal storage is a squat armored bunker with the vault door set in a gatehouse on the front, a steel
  roof slab and a hatch.
"""

import math

from . import common
from . import palette


_APOTHEM = math.cos(math.radians(30.0))  # a hexagon's apothem per unit radius


def _hexagon(name, radius, height, z, radius2=None):
    """A six-sided prism/frustum with no underside (16 triangles), turned so a flat faces the front."""
    obj = common.drop_bottom(common.cylinder(name, radius, height, origin=(0.0, 0.0, z), segments=6, radius2=radius2))
    obj.rotation_euler = (0.0, 0.0, math.radians(30.0))
    return obj


def _vault_door(objects, m, radius, face_y, z, depth):
    """A hexagonal door proud of a face at y = face_y (the front), with a steel locking bar across it (28)."""
    door = common.drop_bottom(common.cylinder("door", radius, depth, segments=6, radius2=radius * 0.85))
    door.rotation_euler = (math.pi / 2.0, 0.0, 0.0)  # grows toward -Y, its open end against the wall
    door.location = (0.0, face_y + depth * 0.2, z)
    common.trim_mat(door)
    objects.append(door)
    bar = common.box("door_bar", radius * 1.7, depth * 0.5, radius * 0.25)
    bar.location = (0.0, face_y - depth * 0.8, z - radius * 0.125)
    m.accent(bar)
    objects.append(bar)


def _capacitor(objects, w, height, hardened, m):
    plinth_h = height * 0.15
    plinth = common.drop_bottom(common.block("plinth", w * 0.97, w * 0.97, plinth_h, top=(w * 0.8, w * 0.8)))
    common.trim_mat(plinth)
    objects.append(plinth)

    drum_r = w * 0.34
    drum_h = height * 0.58
    drum = _hexagon("drum", drum_r, drum_h, plinth_h)
    m.accent(drum)
    objects.append(drum)

    cells = 1 if hardened else 2
    for i in range(cells):
        z = plinth_h + drum_h * (0.3 + 0.35 * i) if not hardened else plinth_h + drum_h * 0.7
        cell = _hexagon("cell", drum_r * 1.06, drum_h * 0.1, z)
        m.glow(cell)
        objects.append(cell)

    drum_top = plinth_h + drum_h
    cap = _hexagon("cap", drum_r * 1.04, height * 0.1, drum_top, radius2=drum_r * 0.7)
    common.trim_mat(cap)
    objects.append(cap)

    if hardened:
        for i in range(4):
            angle = math.radians(90.0 * i)
            slab = common.drop_bottom(
                common.block("armor", w * 0.56, w * 0.17, drum_h * 0.55, top=(w * 0.42, w * 0.06), top_offset=(0.0, -w * 0.06))
            )
            dist = drum_r * _APOTHEM + w * 0.08
            slab.location = (math.cos(angle) * dist, math.sin(angle) * dist, plinth_h)
            slab.rotation_euler = (0.0, 0.0, angle - math.pi / 2.0)
            common.body_mat(slab)
            objects.append(slab)
    else:
        for sx in (-1.0, 1.0):
            post = common.drop_bottom(common.box("terminal", w * 0.08, w * 0.08, height * 0.16, origin=(sx * drum_r * 0.4, 0.0, drum_top + height * 0.05)))
            m.accent(post)
            objects.append(post)


def _silo(objects, w, height, m):
    plinth_h = height * 0.08
    plinth = common.drop_bottom(common.block("plinth", w * 0.98, w * 0.98, plinth_h, top=(w * 0.9, w * 0.9)))
    common.trim_mat(plinth)
    objects.append(plinth)

    tank_r = w * 0.5
    tank_h = height * 0.58
    tank = _hexagon("tank", tank_r, tank_h, plinth_h)
    m.accent(tank)
    objects.append(tank)

    tank_top = plinth_h + tank_h
    roof = _hexagon("roof", tank_r * 1.03, height * 0.24, tank_top, radius2=tank_r * 0.3)
    common.body_mat(roof)
    objects.append(roof)

    _vault_door(objects, m, w * 0.18, -tank_r * _APOTHEM, plinth_h + tank_h * 0.42, w * 0.06)


def _bunker(objects, w, d, height, m):
    body_h = height * 0.68
    slope = min(w, d) * 0.1
    body = common.drop_bottom(
        common.block("bunker", w * 0.97, d * 0.97, body_h, top=(w * 0.97 - 2 * slope, d * 0.97 - 2 * slope))
    )
    common.body_mat(body)
    objects.append(body)

    roof = common.drop_bottom(
        common.block("roof", w * 0.97 - 2 * slope, d * 0.97 - 2 * slope, height * 0.12, top=(w * 0.66, d * 0.66), origin=(0.0, 0.0, body_h))
    )
    m.accent(roof)
    objects.append(roof)
    roof_top = body_h + height * 0.12

    hatch = common.drop_bottom(
        common.block("hatch", w * 0.24, d * 0.24, height * 0.1, top=(w * 0.18, d * 0.18), origin=(w * 0.18, d * 0.12, roof_top))
    )
    common.trim_mat(hatch)
    objects.append(hatch)

    # a gatehouse on the front slope, carrying the vault door
    gate_w = w * 0.38
    gate_d = slope * 1.6
    gate = common.drop_bottom(common.box("gatehouse", gate_w, gate_d, body_h * 0.92, origin=(0.0, -d * 0.485 + gate_d / 2.0, 0.0)))
    common.body_mat(gate)
    objects.append(gate)
    door_r = min(gate_w * 0.36, body_h * 0.36)
    _vault_door(objects, m, door_r, -d * 0.485, body_h * 0.45, min(w, d) * 0.04)


def capacitor(params, hardened):
    """Energy storage: a capacitor, armored when `hardened`."""
    collider = params["collider"]
    m = common.Materials(params["color"], palette.STORAGE_CYAN)
    objects = []
    _capacitor(objects, min(collider["width"], collider["length"]), collider["height"], hardened, m)
    return objects


def silo(params):
    """Metal storage: a steel silo."""
    collider = params["collider"]
    m = common.Materials(params["color"], palette.STORAGE_CYAN)
    objects = []
    _silo(objects, min(collider["width"], collider["length"]), collider["height"], m)
    return objects


def bunker(params):
    """Hardened metal storage: an armored bunker."""
    collider = params["collider"]
    m = common.Materials(params["color"], palette.STORAGE_CYAN)
    objects = []
    _bunker(objects, collider["width"], collider["length"], collider["height"], m)
    return objects
