"""The Studio half of an art upload, and keeping uploads.json tidy.

    python tools/model_pipeline/roblox/record_meshes.py script         # -> build/read_meshes.luau, to run in Studio
    python tools/model_pipeline/roblox/record_meshes.py record <file>  # what that printed, saved to a file
    python tools/model_pipeline/roblox/record_meshes.py prune          # drop what no model uses

`script` fills read_meshes.luau with every model upload_art.py uploaded that is still pending. `record` takes the
"MESHES {...}" lines it printed (anything else in the file is ignored) and records each model's mesh asset ids: every
hash the model was uploaded with has to be there, or it stays pending. Then rebuild (build.ps1 -Stale), and the art
modules name the uploaded meshes.

`prune` removes the meshes nothing uses any more (manifest.used_hashes: neither any model's last build nor any committed
module names them), and the models of generators that no longer exist. check_art.py fails until it has.
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import manifest  # noqa: E402

TEMPLATE_PATH = Path(__file__).resolve().parent / "read_meshes.luau"
SCRIPT_PATH = manifest.BUILD_DIR / "read_meshes.luau"


def script(uploads):
    pending = {name: model for name, model in sorted(uploads["models"].items()) if model["pending"]}
    if not pending:
        sys.exit("no model is waiting for its meshes to be read")
    lines = "\n".join(f"\t{name} = {model['asset_id']}," for name, model in pending.items())
    text = TEMPLATE_PATH.read_text(encoding="utf-8").replace("\t--[[models]]", lines)
    SCRIPT_PATH.parent.mkdir(parents=True, exist_ok=True)
    SCRIPT_PATH.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {SCRIPT_PATH} ({len(pending)} models); run it in Studio and save its output")


def record(uploads, path):
    found = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        marker = line.find("MESHES ")
        if marker >= 0:
            found.update(json.loads(line[marker + len("MESHES ") :]))
    for name, meshes in found.items():
        model = uploads["models"].get(name)
        if model is None:
            print(f"{name}: never uploaded, skipped")
            continue
        missing = [h for h in model["hashes"] if h not in meshes]
        if missing:
            print(f"{name}: its model has no mesh for {', '.join(missing)}; still pending")
            continue
        for mesh_hash in model["hashes"]:
            uploads["assets"][mesh_hash] = {"id": meshes[mesh_hash].removeprefix("rbxassetid://")}
        model["pending"] = False
        print(f"{name}: {len(model['hashes'])} meshes recorded")
    manifest.save_uploads(uploads)


def prune(uploads):
    used = manifest.used_hashes(manifest.load_built())
    names = set(manifest.generator_names())
    dead_meshes = [h for h in uploads["assets"] if h not in used]
    dead_models = [name for name in uploads["models"] if name not in names]
    for h in dead_meshes:
        del uploads["assets"][h]
    for name in dead_models:
        del uploads["models"][name]
    manifest.save_uploads(uploads)
    print(f"pruned {len(dead_meshes)} meshes and {len(dead_models)} models ({', '.join(dead_models) or 'none'})")


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else None
    if command not in ("script", "record", "prune") or len(sys.argv) != (3 if command == "record" else 2):
        sys.exit(__doc__)
    uploads = manifest.load_uploads()
    if command == "script":
        script(uploads)
    elif command == "record":
        record(uploads, sys.argv[2])
    else:
        prune(uploads)


if __name__ == "__main__":
    main()
