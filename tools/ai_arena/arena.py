"""Running arena matches from Python: one at a time (`play`), or many across worker processes (`play_many`).

Each match is its own `lune` process running arena.luau, which reads the match as JSON on stdin and prints its
result as JSON on its last line of output. See README.md.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any, Callable, Iterable

ROOT = Path(__file__).resolve().parents[2]
ARENA = ROOT / "tools" / "ai_arena" / "arena.luau"
LUNE = os.environ.get("LUNE", "lune")
# a match that takes longer than this in real time has hung
TIMEOUT_SECONDS = 1800


def play(match: dict[str, Any], timeout: float = TIMEOUT_SECONDS) -> dict[str, Any]:
    """Plays one match and returns its result; a match that fails returns {"ok": false, "error": ...}."""
    started = time.time()
    try:
        done = subprocess.run(
            [LUNE, "run", str(ARENA), "-"],
            input=json.dumps(match),
            capture_output=True,
            text=True,
            cwd=ROOT,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timed out", "match": match}
    lines = [line for line in done.stdout.splitlines() if line.strip()]
    result: dict[str, Any]
    try:
        result = json.loads(lines[-1])
    except (IndexError, json.JSONDecodeError):
        result = {
            "ok": False,
            "error": f"exit code {done.returncode}: " + (done.stderr or done.stdout)[-2000:],
        }
    result["wall_seconds"] = round(time.time() - started, 2)
    result["match"] = match
    return result


def play_many(
    matches: Iterable[dict[str, Any]],
    workers: int = os.cpu_count() or 4,
    on_result: Callable[[dict[str, Any]], None] | None = None,
) -> list[dict[str, Any]]:
    """Plays every match, `workers` at a time, and returns the results in the order the matches were given.
    `on_result` is called with each as it comes in."""
    matches = list(matches)
    results: list[dict[str, Any] | None] = [None] * len(matches)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(play, match): index for index, match in enumerate(matches)}
        for future in as_completed(futures):
            result = future.result()
            results[futures[future]] = result
            if on_result is not None:
                on_result(result)
    return [result for result in results if result is not None]


if __name__ == "__main__":
    # python tools/ai_arena/arena.py '{"mode": "duel", ...}'  - plays one match and prints its result
    match = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {"mode": "duel"}
    print(json.dumps(play(match), indent=1))
