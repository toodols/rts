"""unit_defs.luau `wall`: a section of dragon's teeth.

A low trim footing with four tapered concrete teeth on it, two by two, each banded in the team's colour a third of
the way up and tipped with a dark point, so a line of them reads as an obstacle from any side. 98 triangles: nothing
that stands on something has an underside, and a band, open at both ends, is only its four sides.
"""

from .shared import common
from .shared import palette

CATEGORY = "entity"
DEF = "wall"


def generate(params):
    accent = params["color"]
    collider = params["collider"]
    width, depth, height = collider["width"], collider["length"], collider["height"]

    objects = []
    footing_h = height * 0.12
    footing = common.drop_bottom(common.block("footing", width * 0.98, depth * 0.98, footing_h, top=(width * 0.9, depth * 0.9)))
    common.trim_mat(footing)
    objects.append(footing)

    tooth_base = width * 0.4
    tooth_top = tooth_base * 0.45
    tooth_h = height - footing_h
    for ix in (-1, 1):
        for iy in (-1, 1):
            x, y = ix * width * 0.23, iy * depth * 0.23
            tooth = common.block("tooth", tooth_base, tooth_base, tooth_h * 0.9, top=(tooth_top, tooth_top),
                                 origin=(x, y, footing_h), drop=("bottom",))
            objects.append(common.paint(tooth, palette.CONCRETE))

            band_z = footing_h + tooth_h * 0.3
            band_w = tooth_base - (tooth_base - tooth_top) * 0.3 + 0.12
            band = common.block("band", band_w, band_w, tooth_h * 0.12, origin=(x, y, band_z), drop=("bottom", "top"))
            objects.append(common.accent_mat(band, accent))

            tip = common.pyramid("tip", tooth_top, tooth_top, tooth_h * 0.1, origin=(x, y, footing_h + tooth_h * 0.9),
                                 base=False)
            objects.append(common.trim_mat(tip))

    return objects
