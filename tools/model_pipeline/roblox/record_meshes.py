"""Record which mesh asset ids an uploaded art model holds, once Studio has read them.

    python tools/model_pipeline/roblox/record_meshes.py meshes.json

`meshes.json` maps each def to what InsertService:LoadAsset found in its model (see upload_art.py): the MeshId of
every MeshPart, by its name, which is the hash of the mesh it was made from:

    { "guard": { "5ce0ade197b6cc2b": "rbxassetid://123", ... }, ... }

Every hash the def's model was uploaded with has to be there, or the def stays pending. Then rebuild the defs, and
their art modules name the uploaded meshes instead of carrying their vertices.
"""

import json
import sys
from pathlib import Path

UPLOADS_PATH = Path(__file__).resolve().parent / "uploads.json"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    found = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    uploads = json.loads(UPLOADS_PATH.read_text(encoding="utf-8"))
    for def_name, meshes in found.items():
        model = uploads["models"].get(def_name)
        if model is None:
            print(f"{def_name}: never uploaded, skipped")
            continue
        missing = [h for h in model["hashes"] if h not in meshes]
        if missing:
            print(f"{def_name}: its model has no mesh for {', '.join(missing)}; still pending")
            continue
        for mesh_hash in model["hashes"]:
            uploads["meshes"][mesh_hash] = meshes[mesh_hash]
        model["pending"] = False
        print(f"{def_name}: {len(model['hashes'])} meshes recorded")
    UPLOADS_PATH.write_text(json.dumps(uploads, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
