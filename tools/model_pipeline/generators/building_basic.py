"""A parametric box building with a peaked or flat roof and floor-line trim.

Params (all optional, defaults shown):
    width: float = 16.0     # studs, X
    depth: float = 12.0     # studs, Z (Blender Y)
    height: float = 10.0    # studs, wall height before the roof
    floors: int = 2         # adds a trim band per floor line, purely decorative
    roof: "peaked" | "flat" = "peaked"
    roof_height: float = 4.0
    wall_color: [r, g, b, a] = [0.55, 0.52, 0.48, 1.0]
    roof_color: [r, g, b, a] = [0.30, 0.18, 0.15, 1.0]
    trim_color: [r, g, b, a] = [0.35, 0.33, 0.30, 1.0]
"""

from . import common


def generate(params):
    width = float(params.get("width", 16.0))
    depth = float(params.get("depth", 12.0))
    height = float(params.get("height", 10.0))
    floors = int(params.get("floors", 2))
    roof = params.get("roof", "peaked")
    roof_height = float(params.get("roof_height", 4.0))
    wall_color = tuple(params.get("wall_color", [0.55, 0.52, 0.48, 1.0]))
    roof_color = tuple(params.get("roof_color", [0.30, 0.18, 0.15, 1.0]))
    trim_color = tuple(params.get("trim_color", [0.35, 0.33, 0.30, 1.0]))

    objects = []

    walls = common.box("walls", width, depth, height)
    common.apply_material(walls, "building_wall", wall_color)
    common.smart_uv(walls)
    objects.append(walls)

    if floors > 1:
        band_height = 0.3
        for floor in range(1, floors):
            z = height * floor / floors
            band = common.box(
                f"trim_{floor}",
                width + 0.2,
                depth + 0.2,
                band_height,
                origin=(0.0, 0.0, z - band_height / 2.0),
            )
            common.apply_material(band, "building_trim", trim_color)
            objects.append(band)

    if roof == "flat":
        roof_obj = common.flat_roof(
            "roof", width + 0.6, depth + 0.6, roof_height, origin=(0.0, 0.0, height)
        )
    else:
        roof_obj = common.gabled_roof(
            "roof", width + 0.6, depth + 0.6, roof_height, origin=(0.0, 0.0, height)
        )
    common.apply_material(roof_obj, "building_roof", roof_color)
    objects.append(roof_obj)

    return objects
