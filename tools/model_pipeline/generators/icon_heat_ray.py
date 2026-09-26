"""HUD icon: heat rays, a wavering beam from an emitter. Written to src/shared/ui_art/ (see shared/icon)."""

from .shared import icon as ic
from .shared import palette

CATEGORY = "hud"


def generate(params):
    beam = ic.wave(-1.2, 1.95, 0.0, 0.32, 1.55, 0.7, segments=26)
    return ic.build(
        "heat_ray",
        [
            ic.layer(ic.place([beam], angle=30.0), palette.ICON_FILL),
            ic.layer(ic.place([ic.circle(-1.35, 0.0, 0.6, 16)], angle=30.0), palette.ICON_FILL),
            ic.layer(ic.place([ic.circle(-1.35, 0.0, 0.24, 10)], angle=30.0), palette.ICON_OUTLINE, rim=None),
        ],
    )
