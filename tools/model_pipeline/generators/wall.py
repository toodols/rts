"""unit_defs.luau `wall`: 2x1x2 cells (8x4x8 studs), a section of dragon's teeth.

A low trim footing with four tapered concrete teeth on it, two by two, each banded in the team's colour a third of
the way up and capped with a darker bevelled top, so a line of them reads as an obstacle from any side.
"""

from . import common

CONCRETE_COLOR = (0.50, 0.52, 0.54, 1.0)  # unit_defs Color3.fromRGB(128, 132, 138)
ACCENT_COLOR = (0.62, 0.64, 0.68, 1.0)


def generate(params):
    width = float(params.get("width", 8.0))
    depth = float(params.get("depth", 8.0))
    height = float(params.get("height", 4.0))

    def concrete_mat(obj):
        common.apply_material(obj, "wall_concrete", CONCRETE_COLOR, roughness=0.8, metallic=0.05)

    def accent_mat(obj):
        common.apply_material(obj, "wall_accent", ACCENT_COLOR, roughness=0.45, metallic=0.3)

    objects = []
    footing_h = height * 0.12
    footing = common.drop_bottom(common.tapered_box("footing", width * 0.98, depth * 0.98, footing_h, width * 0.9, depth * 0.9))
    common.trim_mat(footing)
    objects.append(footing)

    tooth_base = width * 0.4
    tooth_top = tooth_base * 0.45
    tooth_h = height - footing_h
    for ix in (-1, 1):
        for iy in (-1, 1):
            x, y = ix * width * 0.23, iy * depth * 0.23
            tooth = common.tapered_box("tooth", tooth_base, tooth_base, tooth_h * 0.9, tooth_top, tooth_top)
            tooth.location = (x, y, footing_h)
            concrete_mat(tooth)
            objects.append(tooth)

            band_z = footing_h + tooth_h * 0.3
            band_w = tooth_base - (tooth_base - tooth_top) * 0.3 + 0.12
            band = common.box("band", band_w, band_w, tooth_h * 0.12)
            band.location = (x, y, band_z)
            accent_mat(band)
            objects.append(band)

            cap = common.tapered_box("cap", tooth_top, tooth_top, tooth_h * 0.1, tooth_top * 0.6, tooth_top * 0.6)
            cap.location = (x, y, footing_h + tooth_h * 0.9)
            common.trim_mat(cap)
            objects.append(cap)

    return common.finish_all(objects, max_bevel=0.06)
