"""Head-to-head evaluation: how a profile does against others over many games, with margins of error.

    python tools/ai_arena/evaluate.py --profile '{"wave_base": 300}' --against default,raider --scenarios 40
    python tools/ai_arena/evaluate.py --round-robin profiles.json --scenarios 20 --seconds 900

A profile is a named one ("default") or a JSON object of overrides over default; `--profile @file.json` reads it from
a file (a search's champion, say). Each scenario (a map from the pool, a seed, a line taken in turn) is played from
both starts. `--round-robin` plays every pair of the profiles in a JSON file ({name: profile}) and ranks them.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import random
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import arena  # noqa: E402
from scoring import MAPS, duels, points, scenarios  # noqa: E402


def load_profile(text: str) -> Any:
    if text.startswith("@"):
        text = Path(text[1:]).read_text()
    text = text.strip()
    if text.startswith("{"):
        return json.loads(text)
    return text


def wilson(wins: float, games: int, z: float = 1.96) -> tuple[float, float]:
    """The 95% Wilson interval of a rate, `wins` of `games` (points count as fractional wins)."""
    if games == 0:
        return (0.0, 1.0)
    p = wins / games
    denominator = 1 + z * z / games
    middle = (p + z * z / (2 * games)) / denominator
    half = z * math.sqrt(p * (1 - p) / games + z * z / (4 * games * games)) / denominator
    return (max(0.0, middle - half), min(1.0, middle + half))


def points_at(result: dict[str, Any], cap: int) -> float:
    """What a match would have been worth to side a had it been stopped at `cap` seconds: its result if it was over
    by then, and otherwise the tie-break on how things stood at the timeline's last look by then."""
    if result.get("reason") == "commander" and result["seconds"] <= cap:
        return points(result, "a")
    looks = [look for look in result.get("timeline", []) if look["at"] <= cap]
    if not looks:
        return points(result, "a")
    look = looks[-1]
    return points({"reason": "time", "a": look["a"], "b": look["b"]}, "a")


def tally(results: list[dict[str, Any]]) -> dict[str, Any]:
    """How side a did: wins, draws and losses by commander, games that ran out of time, and its mean points."""
    ok = [result for result in results if result.get("ok")]
    wins = sum(1 for r in ok if r.get("reason") == "commander" and r.get("winner") == "a")
    losses = sum(1 for r in ok if r.get("reason") == "commander" and r.get("winner") == "b")
    timed_out = [r for r in ok if r.get("reason") != "commander"]
    total = sum(points(r, "a") for r in ok)
    low, high = wilson(total, len(ok))
    by_line: dict[str, list[float]] = {}
    by_map: dict[str, list[float]] = {}
    for r in ok:
        by_line.setdefault(r["match"]["line"], []).append(points(r, "a"))
        by_map.setdefault(r["match"]["preset"], []).append(points(r, "a"))
    return {
        "games": len(ok),
        "failed": len(results) - len(ok),
        "wins": wins,
        "losses": losses,
        "timed_out": len(timed_out),
        "timed_out_ahead": sum(1 for r in timed_out if points(r, "a") > 0.5),
        "points": round(total / len(ok), 3) if ok else None,
        "interval": [round(low, 3), round(high, 3)],
        "by_line": {key: round(sum(v) / len(v), 3) for key, v in by_line.items()},
        "by_map": {key: round(sum(v) / len(v), 3) for key, v in sorted(by_map.items())},
        "mean_game_seconds": round(sum(r["seconds"] for r in ok) / len(ok), 1) if ok else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--profile", help="the profile to evaluate")
    parser.add_argument("--against", default="default,raider,swarm,turtle", help="comma-separated opponents")
    parser.add_argument("--round-robin", help="JSON file of {name: profile} to play every pair of")
    parser.add_argument("--scenarios", type=int, default=20, help="scenarios per pair (two games each)")
    parser.add_argument("--seconds", type=int, default=900)
    parser.add_argument("--maps", help="comma-separated maps instead of the usual pool")
    parser.add_argument("--line", choices=["bot", "vehicle"])
    parser.add_argument("--seed", type=int, default=12345)
    parser.add_argument("--workers", type=int, default=os.cpu_count() or 8)
    parser.add_argument("--out", help="write every match's result here as it comes in, as JSON lines; matches already there are not played again")
    parser.add_argument("--every", type=int, help="look at the game every so many seconds (for --caps)")
    parser.add_argument("--deaths", action="store_true", help="record every death with what was near it (arena.luau's death_tracker)")
    parser.add_argument("--caps", help="comma-separated earlier time limits to rank by too, from the same games")
    options = parser.parse_args()

    maps = options.maps.split(",") if options.maps else MAPS
    lines = [options.line] if options.line else ["bot", "vehicle"]
    plays = scenarios(options.scenarios, maps, lines, random.Random(options.seed))

    pairs: list[tuple[str, Any, str, Any]] = []
    if options.round_robin:
        entrants = json.loads(Path(options.round_robin).read_text())
        names = list(entrants)
        for i, first in enumerate(names):
            for second in names[i + 1 :]:
                pairs.append((first, entrants[first], second, entrants[second]))
    else:
        assert options.profile, "give --profile or --round-robin"
        mine = load_profile(options.profile)
        for opponent in options.against.split(","):
            pairs.append(("profile", mine, opponent, load_profile(opponent)))

    jobs: list[dict[str, Any]] = []
    owners: list[int] = []
    for index, (_, a, _, b) in enumerate(pairs):
        for match in duels(a, b, plays, options.seconds, options.every):
            if options.deaths:
                match["deaths"] = True
            jobs.append(match)
            owners.append(index)
    # Each result goes to --out as it comes in, and a match already there is not played again, so a run that was
    # stopped carries on from where it was.
    done: dict[str, dict[str, Any]] = {}
    if options.out and Path(options.out).exists():
        for line in open(options.out):
            if line.strip():
                result = json.loads(line)
                if result.get("ok"):
                    done[json.dumps(result["match"], sort_keys=True)] = result
    todo = [match for match in jobs if json.dumps(match, sort_keys=True) not in done]
    print(f"{len(jobs) - len(todo)} of {len(jobs)} matches already played", file=sys.stderr)
    out = open(options.out, "a") if options.out else None

    def keep(result: dict[str, Any]) -> None:
        if out is not None:
            out.write(json.dumps(result) + "\n")
            out.flush()

    for result in arena.play_many(todo, workers=options.workers, on_result=keep):
        done[json.dumps(result["match"], sort_keys=True)] = result
    if out is not None:
        out.close()
    results = [done.get(json.dumps(match, sort_keys=True), {"ok": False, "match": match}) for match in jobs]

    report: dict[str, Any] = {}
    standings: dict[str, list[float]] = {}
    for index, (first, _, second, _) in enumerate(pairs):
        mine = [result for result, owner in zip(results, owners) if owner == index]
        summary = tally(mine)
        report[f"{first} vs {second}"] = summary
        if summary["points"] is not None:
            standings.setdefault(first, []).append(summary["points"])
            standings.setdefault(second, []).append(1 - summary["points"])
    for key, summary in report.items():
        print(key, json.dumps(summary))
    if options.round_robin:
        ranked = sorted(standings.items(), key=lambda item: -sum(item[1]) / len(item[1]))
        print("standings:")
        for name, values in ranked:
            print(f"  {name:24} {sum(values) / len(values):.3f}")
        for cap in [int(value) for value in options.caps.split(",")] if options.caps else []:
            at_cap: dict[str, list[float]] = {}
            for index, (first, _, second, _) in enumerate(pairs):
                mine = [r for r, owner in zip(results, owners) if owner == index and r.get("ok")]
                if mine:
                    value = sum(points_at(r, cap) for r in mine) / len(mine)
                    at_cap.setdefault(first, []).append(value)
                    at_cap.setdefault(second, []).append(1 - value)
            print(f"standings had the games stopped at {cap} s:")
            for name, values in sorted(at_cap.items(), key=lambda item: -sum(item[1]) / len(item[1])):
                print(f"  {name:24} {sum(values) / len(values):.3f}")


if __name__ == "__main__":
    main()
