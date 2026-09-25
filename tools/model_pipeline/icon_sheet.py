"""A contact sheet of the HUD icons (generators/icon_*.py) drawn flat, the way Client.ui.art_icon shows them unlit,
without Blender: each icon big, and beside it at the sizes the HUD uses, on the HUD's dark panel and on a light one.

    python tools/model_pipeline/icon_sheet.py [names...]  ->  tools/model_pipeline/build/icons_sheet.png
"""

import importlib
import sys
import types
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

PIPELINE_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(PIPELINE_ROOT))

# the generators only reach for Blender when they build, which this never does
for stub in ("bpy", "bmesh", "mathutils"):
    sys.modules.setdefault(stub, types.ModuleType(stub))

ic = importlib.import_module("generators.icon_common")

SUPERSAMPLE = 4
BIG = 160
SMALL = (48, 32, 24)
EXTENT = 2.3  # half the canvas, in the icons' own units
CELL_PAD = 10
DARK = (43, 46, 56)
LIGHT = (214, 218, 226)
SHEET = (18, 19, 24)
LABEL = (200, 204, 214)


def _to_px(point, size):
    x, y = point
    scale = size / (2 * EXTENT)
    return ((x + EXTENT) * scale, (EXTENT - y) * scale)


def _shape_mask(shape, size):
    outer, holes = shape
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon([_to_px(p, size) for p in outer], fill=255)
    for hole in holes:
        draw.polygon([_to_px(p, size) for p in hole], fill=0)
    return mask


def _rgb(color):
    return tuple(round(c * 255) for c in color[:3])


def render(layers, size, background):
    """The layers drawn back to front at `size` pixels square: in each, every outline and then every fill, as the
    build stacks them."""
    big = size * SUPERSAMPLE
    image = Image.new("RGB", (big, big), background)
    for spec in layers:
        if spec["rim"] is not None:
            for shape in spec["shapes"]:
                image.paste(_rgb(spec["rim"]), mask=_shape_mask(ic.grow(shape, spec["rim_width"]), big))
        for shape in spec["shapes"]:
            image.paste(_rgb(spec["color"]), mask=_shape_mask(shape, big))
    return image.resize((size, size), Image.LANCZOS)


def capture(name):
    """The layers generators/icon_<name>.py draws."""
    captured = {}
    module = importlib.import_module(f"generators.icon_{name}")
    real_build = ic.build

    def fake_build(prefix, layers):
        assert ic.colours(layers) <= set(ic.PALETTE), f"icon {prefix} uses a colour of its own"
        captured["layers"] = layers
        return []

    ic.build = fake_build
    try:
        module.generate({})
    finally:
        ic.build = real_build
    return captured["layers"]


def main(names):
    if not names:
        names = sorted(p.stem[len("icon_") :] for p in (PIPELINE_ROOT / "generators").glob("icon_*.py") if p.stem != "icon_common")
    font = ImageFont.load_default()
    smalls_width = sum(SMALL) + CELL_PAD * len(SMALL)
    cell_w = BIG + CELL_PAD + smalls_width + CELL_PAD
    cell_h = BIG + 22
    columns = 4
    rows = (len(names) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * cell_w + CELL_PAD, rows * cell_h + CELL_PAD), SHEET)
    draw = ImageDraw.Draw(sheet)
    for i, name in enumerate(names):
        layers = capture(name)
        x0 = CELL_PAD + (i % columns) * cell_w
        y0 = CELL_PAD + (i // columns) * cell_h
        sheet.paste(render(layers, BIG, DARK), (x0, y0))
        x = x0 + BIG + CELL_PAD
        for size in SMALL:
            sheet.paste(render(layers, size, DARK), (x, y0))
            sheet.paste(render(layers, size, LIGHT), (x, y0 + SMALL[0] + CELL_PAD))
            x += size + CELL_PAD
        used = len(ic.colours(layers))
        draw.text((x0, y0 + BIG + 4), f"{name}  ({used} colours)", fill=LABEL, font=font)
    out = PIPELINE_ROOT / "build" / "icons_sheet.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main(sys.argv[1:])
