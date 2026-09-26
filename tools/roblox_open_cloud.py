"""Roblox Open Cloud as the tools use it: which API key, which creator the assets belong to, uploading a file as an
asset, and the asset-id stores the pipelines keep (tools/model_pipeline/roblox/uploads.json,
tools/sound_pipeline/uploads.json). Plain Python; needs `requests`.

The API key is the first of --api-key, $ROBLOX_API_KEY and rbxopencloudkey.txt at the repository's root (gitignored).
It needs asset:read and asset:write for the creator, which roblox_creator.json names.

An asset-id store is JSON: `assets` maps each thing uploaded (a mesh's hash, a sound's name) to `{"id": "<asset id>"}`
plus whatever the pipeline keeps with it (a sound's sha256); a pipeline may keep more beside `assets` (the art
models it uploaded).
"""

import json
import os
import sys
import time
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
KEY_PATH = REPO_ROOT / "rbxopencloudkey.txt"
CREATOR_PATH = TOOLS_DIR / "roblox_creator.json"
ASSETS_URL = "https://apis.roblox.com/assets/v1"
POLL_SECONDS = 3.0
TIMEOUT_SECONDS = 300.0


def add_key_argument(parser):
    parser.add_argument("--api-key", default=None, help="the Open Cloud API key (default: $ROBLOX_API_KEY, then rbxopencloudkey.txt)")


def api_key(given):
    """The key: `given` (--api-key), $ROBLOX_API_KEY, or rbxopencloudkey.txt, the first there is."""
    if given:
        return given
    if os.environ.get("ROBLOX_API_KEY"):
        return os.environ["ROBLOX_API_KEY"]
    if KEY_PATH.is_file():
        return KEY_PATH.read_text(encoding="utf-8").strip()
    sys.exit(f"no API key: pass --api-key, set ROBLOX_API_KEY, or put it in {KEY_PATH}")


def creator():
    """The creationContext creator of every upload, from roblox_creator.json."""
    config = json.loads(CREATOR_PATH.read_text(encoding="utf-8"))
    field = {"User": "userId", "Group": "groupId"}[config["type"]]
    return {field: str(config["id"])}


def upload(path, asset_type, content_type, display_name, description, key):
    """Uploads the file at `path` as a new asset and waits for Roblox to finish processing it; returns its asset id.
    Exits with Roblox's reason if it is refused or fails."""
    import requests

    request = {
        "assetType": asset_type,
        "displayName": display_name,
        "description": description,
        "creationContext": {"creator": creator()},
    }
    with Path(path).open("rb") as file:
        response = requests.post(
            f"{ASSETS_URL}/assets",
            headers={"x-api-key": key},
            data={"request": json.dumps(request)},
            files={"fileContent": (Path(path).name, file, content_type)},
        )
    if not response.ok:
        sys.exit(f"{display_name}: upload refused ({response.status_code}): {response.text}")
    operation_path = response.json()["path"]
    deadline = time.time() + TIMEOUT_SECONDS
    while time.time() < deadline:
        status = requests.get(f"{ASSETS_URL}/{operation_path}", headers={"x-api-key": key})
        if not status.ok:
            sys.exit(f"{display_name}: could not read the upload's status ({status.status_code}): {status.text}")
        body = status.json()
        if body.get("done"):
            if "error" in body:
                sys.exit(f"{display_name}: upload failed: {body['error']}")
            return str(body["response"]["assetId"])
        time.sleep(POLL_SECONDS)
    sys.exit(f"{display_name}: timed out waiting for Roblox to finish processing the upload")


def load_store(path):
    """An asset-id store (see the module docstring); empty if there is none yet."""
    path = Path(path)
    if path.is_file():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"assets": {}}


def save_store(path, store):
    Path(path).write_text(json.dumps(store, indent=2, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
