"""Prints the arena's ai_match numbers in the shape a Studio run of the same test is read in, to hold them side by side.

    python tools/ai_arena/validate.py '{"seconds": 180, "every": 60, "random_seed": 42}' [--root PATH]

`--root` plays the game's source at PATH (another checkout) instead of this one's.
"""

import json
import sys

import arena

args = json.loads(sys.argv[1]) if len(sys.argv) > 1 and sys.argv[1].startswith("{") else {}
args["mode"] = "ai_match"
if "--root" in sys.argv:
    args["root"] = sys.argv[sys.argv.index("--root") + 1]
result = arena.play(args)
if not result.get("ok"):
    print(result.get("error"))
    sys.exit(1)
for snapshot in result["snapshots"]:
    for key in sorted(k for k in snapshot if k.startswith("team_")):
        team = snapshot[key]
        counts = ", ".join(f"{name} {count}" for name, count in sorted(team["counts"].items()))
        print(f"{snapshot['at']:>5}s {key}: metal {team['metal_income']}, energy {team['energy_income']}: {counts}")
print(f"real seconds {result['real_seconds']}, duplicate labs {result['duplicate_labs']}")
