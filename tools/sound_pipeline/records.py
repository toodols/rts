"""Where the sound pipeline keeps its files, and how a sound is known: plain Python, which synth.py, review.py and
upload_sounds.py all read.

- build/<name>.wav and .ogg: what synth.py made; build/uploaded/: a copy of each as it was last uploaded.
- approved.json: each approved sound's `digest`, as it was when it was listened to (review.py approve).
- uploads.json: what is on Roblox, an asset-id store (tools/roblox_open_cloud.py): each sound's id and the digest of
  what was uploaded.
"""

import hashlib
import json
from pathlib import Path

PIPELINE = Path(__file__).resolve().parent
BUILD = PIPELINE / "build"
UPLOADED = BUILD / "uploaded"
APPROVED_PATH = PIPELINE / "approved.json"
UPLOADS_PATH = PIPELINE / "uploads.json"


def digest(name):
    """What a sound is as built now: the hash of its .wav, not its .ogg, which the encoder stamps with a random stream
    serial."""
    return hashlib.sha256((BUILD / f"{name}.wav").read_bytes()).hexdigest()


def load_approved():
    return json.loads(APPROVED_PATH.read_text()) if APPROVED_PATH.is_file() else {}


def save_approved(approved):
    APPROVED_PATH.write_text(json.dumps(dict(sorted(approved.items())), indent=2) + "\n", newline="\n")
