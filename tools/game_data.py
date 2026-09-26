"""The numbers the tools take from the game itself instead of keeping copies of them: shared/world_scale's constants;
from shared/unit_defs, each def's collider and colour, whether it floats and what art it is drawn in if it is a
reclaimable; and each BAR map's makers as shared/bar_maps/rights credits them. They are read through the game's own
modules by tools/game_data.luau (lune, on the engine's stand-in in tools/lib, as the arena and the headless tests run
the game).

    import game_data
    data = game_data.load()
    data["scale"]["ELMOS_PER_STUD"], data["defs"]["grunt"]["collider"], data["map_credits"]["rifted"]

A def's `color` is its Color3 as 0-255 bytes, `floats` whether it rides the water's surface, and a reclaimable's
`feature_art` the art it is drawn in; a collider is in studs, `{shape = "box", width, height, length}` or
`{shape = "capsule", radius, height, width, length}` (a capsule's width and length are BAR's, which its radius
rounds up to a circle). Plain Python: usable from Blender's Python as well as the command line.
"""

import json
import subprocess
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
SCRIPT = TOOLS_DIR / "game_data.luau"


def load(root=REPO_ROOT):
    """The game's numbers, as the checkout at `root` has them."""
    result = subprocess.run(
        ["lune", "run", str(SCRIPT), str(Path(root).resolve())],
        capture_output=True,
        text=True,
        cwd=REPO_ROOT,
    )
    if result.returncode != 0:
        raise SystemExit(f"tools/game_data.luau failed:\n{result.stdout}{result.stderr}")
    return json.loads(result.stdout)
