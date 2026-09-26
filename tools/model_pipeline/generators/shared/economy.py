"""Helpers shared by the economy buildings (solar collectors, metal extractors, wind turbine, tidal generator)
and the scavenger beacons.

These models have a hard budget of 100 triangles each, so they are built from lean hand-made meshes: a common.Faces
collects faces (lofts between two rings, pyramids, flat quads) into one object, and leaves out whatever can never be
seen -- the underside of anything standing on the ground or floating, the top of a mast that a nacelle sits on, the
inner end of a hinged panel."""

import math

import mathutils

from . import common
from . import palette


def cell(obj):
    common.paint(obj, palette.SOLAR_CELL)
    return obj


def scav_dark(obj):
    common.paint(obj, palette.SCAVENGER_DARK)
    return obj


def matrix(location=(0.0, 0.0, 0.0), rotation=(0.0, 0.0, 0.0)):
    """A rigid transform: rotate by the XYZ euler `rotation` (radians), then move to `location`."""
    return mathutils.Matrix.Translation(location) @ mathutils.Euler(rotation, "XYZ").to_matrix().to_4x4()


def wedge(faces, angle, r_in, r_out, width, z0, height, m=None):
    """A buttress/claw: a right-triangle profile (flat on the ground, vertical at r_in, sloping down to r_out)
    extruded `width` across, pointing outward at `angle`. Its underside is left out."""
    base = matrix((0.0, 0.0, z0), (0.0, 0.0, angle - math.pi / 2))
    if m is not None:
        base = m @ base
    hw = width / 2.0
    # profile points (local y outward, z up), counter-clockwise seen from +x
    prof = [(r_in, 0.0), (r_out, 0.0), (r_in, height)]
    ring_a = [(-hw, y, z) for y, z in prof]
    ring_b = [(hw, y, z) for y, z in prof]
    # sides: 0 = underside, 1 = slope, 2 = inner face
    faces.loft(ring_a, ring_b, base, cap_a=True, cap_b=True, skip=(0,))
    return faces
