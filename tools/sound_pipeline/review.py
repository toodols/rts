"""Listen to the synthesized sounds before they are uploaded, and approve the ones that may go up.

    python tools/sound_pipeline/review.py                  # writes build/review.html and opens it
    python tools/sound_pipeline/review.py approve dgun ... # approves those sounds as they are built now
    python tools/sound_pipeline/review.py approve --all

The page plays each build/<name>.ogg, the very file upload_sounds.py sends, beside the version on Roblox now
(build/uploaded/<name>.ogg, kept by upload_sounds.py) where there is one. The two are loudness-matched, since the
louder of two sounds tends to seem the better one; the game sets each sound's volume itself.

Approving records the hash of a sound's .wav in approved.json. upload_sounds.py uploads nothing that is not
approved as it is built now, so a sound changed after it was approved has to be listened to again.
"""

import argparse
import hashlib
import html
import json
import sys
import webbrowser
from pathlib import Path

import numpy as np
from scipy.io import wavfile

import synth

PIPELINE = Path(__file__).resolve().parent
BUILD = PIPELINE / "build"
UPLOADED = BUILD / "uploaded"
APPROVED_PATH = PIPELINE / "approved.json"
UPLOADS_PATH = PIPELINE / "uploads.json"


def digest(name: str) -> str:
    return hashlib.sha256((BUILD / f"{name}.wav").read_bytes()).hexdigest()


def load(path: Path) -> dict:
    return json.loads(path.read_text()) if path.is_file() else {}


def loudness(wav: Path) -> float:
    _, samples = wavfile.read(wav)
    return synth.loudness_db(samples.astype(np.float64) / 32768)


def status(name: str, approved: dict, uploads: dict) -> str:
    current = digest(name)
    if uploads.get(name, {}).get("sha256") == current:
        return "uploaded"
    if approved.get(name) == current:
        return "approved, not uploaded"
    return "needs review"


def page() -> str:
    approved, uploads = load(APPROVED_PATH), load(UPLOADS_PATH)
    rows = []
    for name, make in synth.SOUNDS.items():
        if not (BUILD / f"{name}.ogg").is_file():
            continue
        state = status(name, approved, uploads)
        new_db = loudness(BUILD / f"{name}.wav")
        old_wav = UPLOADED / f"{name}.wav"
        old_db = loudness(old_wav) if old_wav.is_file() else None
        # the louder of the two is turned down to the quieter one
        new_volume = min(1.0, 10 ** ((old_db - new_db) / 20)) if old_db is not None else 1.0
        old_volume = min(1.0, 10 ** ((new_db - old_db) / 20)) if old_db is not None else 1.0
        old_player = (
            f'<audio controls preload="auto" src="uploaded/{name}.ogg" data-volume="{old_volume:.3f}"></audio>'
            if (UPLOADED / f"{name}.ogg").is_file()
            else '<span class="none">not on Roblox yet</span>'
        )
        rows.append(f"""
      <section class="sound {state.split(',')[0].replace(' ', '-')}">
        <header><h2>{name}</h2><span class="state">{state}</span></header>
        <p>{html.escape(" ".join((make.__doc__ or "").split()))}</p>
        <div class="players">
          <label>New<audio controls preload="auto" src="{name}.ogg" data-volume="{new_volume:.3f}"></audio></label>
          <label>On Roblox now{old_player}</label>
        </div>
        <code>python tools/sound_pipeline/review.py approve {name}</code>
      </section>""")
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sound Review</title>
<style>
  :root {{ --bg: #f6f5f2; --card: #fff; --text: #1d1d1b; --muted: #6b6a66; --line: #e2e0da;
           --review: #b45309; --approved: #1d4ed8; --uploaded: #15803d; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg: #161615; --card: #1f1f1d; --text: #ecebe7; --muted: #a09f9a; --line: #33322f;
             --review: #f59e0b; --approved: #60a5fa; --uploaded: #4ade80; }}
  }}
  body {{ background: var(--bg); color: var(--text); font: 15px/1.5 system-ui, sans-serif; margin: 0; padding: 24px 16px; }}
  main {{ max-width: 860px; margin: 0 auto; display: grid; gap: 14px; }}
  h1 {{ font-size: 22px; margin: 0 0 4px; }}
  .intro {{ color: var(--muted); margin: 0 0 8px; }}
  .sound {{ background: var(--card); border: 1px solid var(--line); border-left: 4px solid var(--review);
            border-radius: 8px; padding: 14px 16px; }}
  .sound.approved {{ border-left-color: var(--approved); }}
  .sound.uploaded {{ border-left-color: var(--uploaded); }}
  header {{ display: flex; justify-content: space-between; align-items: baseline; gap: 12px; }}
  h2 {{ font-size: 17px; margin: 0; font-family: ui-monospace, monospace; }}
  .state {{ font-size: 13px; color: var(--review); }}
  .approved .state {{ color: var(--approved); }}
  .uploaded .state {{ color: var(--uploaded); }}
  p {{ margin: 6px 0 10px; color: var(--muted); }}
  .players {{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; }}
  @media (max-width: 640px) {{ .players {{ grid-template-columns: 1fr; }} }}
  label {{ display: grid; gap: 4px; font-size: 13px; color: var(--muted); }}
  audio {{ width: 100%; }}
  .none {{ font-style: italic; padding: 10px 0; }}
  code {{ display: block; margin-top: 10px; font-size: 12px; color: var(--muted); overflow-wrap: anywhere; }}
</style>
</head>
<body>
<main>
  <h1>Sound review</h1>
  <p class="intro">Each new sound is the exact .ogg that would be uploaded. The two players are loudness-matched,
  so compare them on sound, not volume.</p>
  {"".join(rows)}
</main>
<script>
  for (const audio of document.querySelectorAll("audio[data-volume]")) audio.volume = Number(audio.dataset.volume);
</script>
</body>
</html>
"""


def approve(names: list[str]):
    approved = load(APPROVED_PATH)
    for name in names:
        if not (BUILD / f"{name}.wav").is_file():
            sys.exit(f"no build/{name}.wav: run synth.py first")
        approved[name] = digest(name)
        print(f"{name}: approved")
    APPROVED_PATH.write_text(json.dumps(dict(sorted(approved.items())), indent=2) + "\n", newline="\n")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", nargs="?", choices=["approve"])
    parser.add_argument("names", nargs="*")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()
    if args.command == "approve":
        names = list(synth.SOUNDS) if args.all else args.names
        if not names:
            sys.exit("name the sounds to approve, or pass --all")
        approve(names)
        return
    out = BUILD / "review.html"
    out.write_text(page(), encoding="utf-8")
    print(out)
    if not args.no_open:
        webbrowser.open(out.as_uri())


if __name__ == "__main__":
    main()
