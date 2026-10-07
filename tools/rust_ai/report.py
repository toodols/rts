"""How the Rust AI did in a file of arena results (evaluate.py's --out, or search.py's matches.jsonl): its points
against each opponent, and how efficiently each side played its economy (arena.luau's efficiency_tracker), the Rust
AI's beside its opponents', on the mean:

- float: seconds of metal income it sat on;   full: share of seconds its metal storage was full;
- stall: share of seconds it had no energy;   bp/inc: its buildpower over its metal income;
- idle: share of builder-seconds with no orders;   lab idle: share of lab-seconds with nothing queued.

    python tools/rust_ai/report.py tools/rust_ai/runs/eval5.jsonl [more.jsonl ...]
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "ai_arena"))
from scoring import points  # noqa: E402

KEYS = [
    ("float_seconds", "float"),
    ("metal_full_share", "full"),
    ("energy_stall_share", "stall"),
    ("buildpower_per_income", "bp/inc"),
    ("builder_idle_share", "idle"),
    ("lab_idle_share", "lab idle"),
]


def main() -> None:
    games: dict[str, list[dict]] = defaultdict(list)
    for path in sys.argv[1:]:
        for line in open(path):
            if not line.strip():
                continue
            r = json.loads(line)
            if not r.get("ok"):
                continue
            match = r.get("match", {})
            a, b = match.get("a", {}), match.get("b", {})
            rust = "a" if a.get("engine") == "rust" else "b" if b.get("engine") == "rust" else None
            if rust is None:
                continue
            other = "b" if rust == "a" else "a"
            opponent = (match.get(other) or {}).get("profile") or r.get("opponent") or "rust"
            games[opponent].append({"points": points(r, rust), "rust": r[rust], "other": r[other], "result": r, "side": rust})

    def mean(values: list[float]) -> float:
        return sum(values) / len(values) if values else float("nan")

    header = f"{'opponent':10} {'games':>5} {'points':>6} {'won':>4} {'lost':>4} | " + " ".join(f"{label:>17}" for _, label in KEYS)
    print(header)
    print(" " * 34 + "| " + " ".join(f"{'rust / them':>17}" for _ in KEYS))
    for opponent, rows in sorted(games.items()):
        won = sum(1 for g in rows if g["result"].get("winner") == g["side"])
        lost = sum(1 for g in rows if g["result"].get("winner") not in (None, g["side"]))
        cells = []
        for key, _ in KEYS:
            mine = mean([g["rust"]["efficiency"][key] for g in rows if "efficiency" in g["rust"]])
            theirs = mean([g["other"]["efficiency"][key] for g in rows if "efficiency" in g["other"]])
            cells.append(f"{mine:>8.3g} / {theirs:<6.3g}")
        print(f"{opponent:10} {len(rows):>5} {mean([g['points'] for g in rows]):>6.3f} {won:>4} {lost:>4} | " + " ".join(cells))


if __name__ == "__main__":
    main()
