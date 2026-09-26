"""Whether spreading out pays against splash: staged fights (arena.luau's "fight" mode) of a group of first-tier units
against splash-heavy enemies (Pounders, Janus), played with side a sent to one point and again with it spread out in
the AI's formation (the profile's spread, server/ai/squads.luau's `formation`) at each given spacing.

    python tools/ai_arena/formation_check.py --spacings 0,6,10 --seeds 6

Reports, for each spacing, the share of side a's worth left at the end and of side b's, their margin (a's share less
b's), and how often a won, over every fight.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from statistics import mean

sys.path.insert(0, str(Path(__file__).resolve().parent))

import arena  # noqa: E402

FIGHTS = [
    {"a": [{"def": "thug", "count": 10}], "b": [{"def": "pounder", "count": 4}]},
    {"a": [{"def": "grunt", "count": 16}], "b": [{"def": "pounder", "count": 3}]},
    {"a": [{"def": "thug", "count": 8}, {"def": "grunt", "count": 6}], "b": [{"def": "janus", "count": 4}]},
    {"a": [{"def": "aggravator", "count": 8}], "b": [{"def": "pounder", "count": 2}, {"def": "janus", "count": 2}]},
]

# the same without splash on the other side, to see that spreading out costs nothing where there is none to avoid
CONTROL = [
    {"a": [{"def": "thug", "count": 10}], "b": [{"def": "thug", "count": 9}]},
    {"a": [{"def": "grunt", "count": 16}], "b": [{"def": "grunt", "count": 14}]},
    {"a": [{"def": "thug", "count": 8}, {"def": "grunt", "count": 6}], "b": [{"def": "aggravator", "count": 6}]},
    {"a": [{"def": "aggravator", "count": 8}], "b": [{"def": "thug", "count": 8}]},
]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--spacings", default="0,6,10")
    parser.add_argument("--seeds", type=int, default=6)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--control", action="store_true", help="fight enemies without splash instead")
    args = parser.parse_args()
    spacings = [float(x) for x in args.spacings.split(",")]
    matches = []
    for spacing in spacings:
        for fight in CONTROL if args.control else FIGHTS:
            for seed in range(1, args.seeds + 1):
                matches.append(
                    {
                        "mode": "fight",
                        "preset": "highlands",
                        "seed": 1337,
                        "random_seed": seed,
                        "distance": 110 + seed * 5,
                        "centre_z": (seed - 3) * 20,
                        "formation": spacing,
                        "seconds": 90,
                        **fight,
                    }
                )
    results = arena.play_many(matches, workers=args.workers)
    for spacing in spacings:
        rows = [r for r in results if r.get("ok") and r["match"]["formation"] == spacing]
        share_a = [r["real"]["worth"]["a"] / max(1e-9, r["real"]["start_worth"]["a"]) for r in rows]
        share_b = [r["real"]["worth"]["b"] / max(1e-9, r["real"]["start_worth"]["b"]) for r in rows]
        print(
            json.dumps(
                {
                    "spacing": spacing,
                    "fights": len(rows),
                    "a_left": round(mean(share_a), 3),
                    "b_left": round(mean(share_b), 3),
                    "margin": round(mean(r["real"]["margin"] for r in rows), 3),
                    "a_won": sum(1 for r in rows if r["real"]["winner"] == "a"),
                    "failed": sum(1 for r in results if not r.get("ok") and r["match"]["formation"] == spacing),
                }
            )
        )
    for r in results:
        if not r.get("ok"):
            print(r.get("error"))
            break


if __name__ == "__main__":
    main()
