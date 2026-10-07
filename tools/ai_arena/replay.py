"""Replays of arena games (arena.luau's `record`; src/server/replay.luau plays them back).

    python tools/ai_arena/replay.py verify <replay>          plays it back headless and checks every jump point
    python tools/ai_arena/replay.py studio <replay> [--play] loads it into the open Studio (the game place) and sets
                                                             it to play; --play also starts the Play session
    python tools/ai_arena/replay.py clear                    takes a loaded replay out of Studio again
    python tools/ai_arena/replay.py list [folder]            the replays under tools/ai_arena/runs/replays

<replay> is the folder a recorded duel was kept in. Once loaded, Play in Studio watches it from the start; in the game
the command bar's `replay seek 90%` (or 10:00, or 600) goes anywhere in it, from the nearest jump point, and `replay
status` says whether it is still the game that was recorded. pause and warp work on it as on any game.

Loading writes the replay into the place's ServerStorage (about 1.35 times its size on disk): `clear` it before
saving the place.
"""

from __future__ import annotations

import base64
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from studio_mcp import StudioSession  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
REPLAYS = ROOT / "tools" / "ai_arena" / "runs" / "replays"
# what one StringValue holds, in base64 characters
PART = 100_000

CLEAR = """
local ServerStorage = game:GetService "ServerStorage"
local old = ServerStorage:FindFirstChild "Replay"
if old then old:Destroy() end
workspace:SetAttribute("Replay", nil)
return "cleared"
"""


def verify(folder: Path) -> int:
    return subprocess.run(["lune", "run", "tools/ai_arena/replay_verify.luau", str(folder)], cwd=ROOT).returncode


def studio(folder: Path, play: bool) -> None:
    manifest_text = (folder / "manifest.json").read_text()
    manifest = json.loads(manifest_text)
    session = StudioSession()
    try:
        studio_id = session.game_studio()
        mode = session.call("get_studio_state", {"studio_id": studio_id})
        if "Edit" not in mode.splitlines()[0]:
            raise RuntimeError("Studio is playing; stop it first, so that the replay goes into the place being edited")

        def edit(code: str) -> str:
            return session.call("execute_luau", {"studio_id": studio_id, "datamodel_type": "Edit", "code": code})

        edit(CLEAR)
        edit(
            'local ServerStorage = game:GetService "ServerStorage"\n'
            'local folder = Instance.new "Folder"\nfolder.Name = "Replay"\n'
            'local manifest = Instance.new "StringValue"\nmanifest.Name = "manifest"\n'
            f"manifest.Value = [==[{manifest_text}]==]\nmanifest.Parent = folder\n"
            'local keyframes = Instance.new "Folder"\nkeyframes.Name = "keyframes"\nkeyframes.Parent = folder\n'
            "folder.Parent = ServerStorage\nreturn 'ok'"
        )
        total = len(manifest["keyframes"])
        for index, keyframe in enumerate(manifest["keyframes"], 1):
            text = base64.b64encode((folder / f"{keyframe['file']}.bin").read_bytes()).decode("ascii")
            parts = [text[at:at + PART] for at in range(0, len(text), PART)]
            edit(
                'local keyframes = game:GetService("ServerStorage").Replay.keyframes\n'
                f'local parts = Instance.new "Folder"\nparts.Name = "{keyframe["file"]}"\nparts.Parent = keyframes\nreturn "ok"'
            )
            for number, part in enumerate(parts, 1):
                edit(
                    f'local parts = game:GetService("ServerStorage").Replay.keyframes["{keyframe["file"]}"]\n'
                    f'local value = Instance.new "StringValue"\nvalue.Name = "{number}"\n'
                    f"value.Value = [==[{part}]==]\nvalue.Parent = parts\nreturn 'ok'"
                )
            print(f"\rloaded jump point {index} of {total}", end="", flush=True)
        print()
        # a game the Rust AI played: what it told its sides each second, as JSON in parts
        if manifest.get("orders"):
            text = (folder / manifest["orders"]).read_text()
            parts = [text[at:at + PART] for at in range(0, len(text), PART)]
            edit(
                'local orders = Instance.new "Folder"\norders.Name = "orders"\n'
                'orders.Parent = game:GetService("ServerStorage").Replay\nreturn "ok"'
            )
            for number, part in enumerate(parts, 1):
                edit(
                    'local orders = game:GetService("ServerStorage").Replay.orders\n'
                    f'local value = Instance.new "StringValue"\nvalue.Name = "{number}"\n'
                    f"value.Value = [==[{part}]==]\nvalue.Parent = orders\nreturn 'ok'"
                )
            print(f"loaded the Rust AI's orders ({len(parts)} parts)")
        edit('workspace:SetAttribute("Replay", true)\nreturn "ok"')
        print(f"loaded {folder.name}: {manifest['map']['preset']}, {manifest['length']} s, "
              f"{total} jump points {manifest['keyframe_every']} s apart")
        if play:
            print(session.call("start_stop_play", {"studio_id": studio_id, "is_start": True}))
        else:
            print("press Play in Studio to watch it")
    finally:
        session.close()


def clear() -> None:
    session = StudioSession()
    try:
        studio_id = session.game_studio()
        print(session.call("execute_luau", {"studio_id": studio_id, "datamodel_type": "Edit", "code": CLEAR}))
    finally:
        session.close()


def list_replays(root: Path) -> None:
    for manifest_path in sorted(root.glob("**/manifest.json")):
        manifest = json.loads(manifest_path.read_text())
        sides = manifest.get("sides", {})
        result = manifest.get("result", {})
        a = sides.get("a", {}).get("profile") or sides.get("a", {}).get("engine", "?")
        b = sides.get("b", {}).get("profile") or sides.get("b", {}).get("engine", "?")
        print(f"{manifest_path.parent.relative_to(root)}: {a} vs {b}, {manifest['length']} s, "
              f"winner {result.get('winner')} ({result.get('reason')})")


def main() -> None:
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    action = sys.argv[1]
    if action == "verify":
        sys.exit(verify(Path(sys.argv[2]).resolve()))
    elif action == "studio":
        studio(Path(sys.argv[2]).resolve(), "--play" in sys.argv)
    elif action == "clear":
        clear()
    elif action == "list":
        list_replays(Path(sys.argv[2]) if len(sys.argv) > 2 else REPLAYS)
    else:
        print(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main()
