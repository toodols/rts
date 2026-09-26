"""Checks of how an AI profile behaves, rather than of who wins: duels played with arena.luau's `watch`, and what it
saw, summed over the games, for side a (the profile being looked at) and side b.

    python tools/ai_arena/behaviour.py --a sim_barb --b raider --games 8 --seconds 900 --out runs/aib/before.jsonl
    python tools/ai_arena/behaviour.py --summarise runs/aib/before.jsonl

Each game is a scenario (a map from scoring.MAPS and a seed) played on the bot line, from both starts in turn. What is
reported, per game on average:

- builder-seconds with an extractor to build on a spot an enemy's extractor already stands on, and of those the seconds
  spent at the spot; builder-seconds at a build site with something in the way;
- raids: how many were sent, the targets each saw destroyed before it came home, and how they ended;
- intruders: the enemy's armed units (not its commander) in its territory (near home or one of its extractors), their
  seconds there all told in the first ten minutes, the mean length of a stay, and the share of stays that ended in the
  intruder's death;
- its extractors lost in the first ten minutes, and the points it took (scoring.points).

A side is a profile's name or a JSON object {"profile": name, "overrides": {...}}.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
from pathlib import Path
from statistics import mean
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

import arena  # noqa: E402
from scoring import MAPS, points  # noqa: E402


def side(text: str) -> dict[str, Any]:
    text = text.strip()
    if text.startswith("{"):
        return json.loads(text)
    return {"profile": text}


def matches(a: dict[str, Any], b: dict[str, Any], games: int, seconds: int, seed: int) -> list[dict[str, Any]]:
    rng = random.Random(seed)
    out = []
    for index in range(games):
        if index % 2 == 0:
            preset, map_seed = rng.choice(MAPS), rng.randrange(1, 1_000_000)
        out.append(
            {
                "mode": "duel",
                "preset": preset,
                "seed": map_seed,
                "line": "bot",
                "seconds": seconds,
                "swap": index % 2 == 1,
                "watch": True,
                "a": a,
                "b": b,
            }
        )
    return out


def summarise(results: list[dict[str, Any]]) -> dict[str, Any]:
    ok = [r for r in results if r.get("ok")]
    out: dict[str, Any] = {"games": len(ok), "failed": len(results) - len(ok)}
    if not ok:
        return out
    for name in ("a", "b"):
        watch = [r["watch"][name] for r in ok]
        early = [w["early"] for w in watch]
        totals = [w["totals"] for w in watch]
        raids = [raid for r in ok for raid in (r.get(f"{name}_report") or {}).get("raids", [])]
        kills = [raid.get("kills", 0) for raid in raids]
        ended: dict[str, int] = {}
        for raid in raids:
            key = raid.get("ended") or "out"
            ended[key] = ended.get(key, 0) + 1
        stays = sum(e["intruder_stays"] for e in early)
        other = "b" if name == "a" else "a"
        reports = [r.get(f"{name}_report") or {} for r in ok]
        hunts = [h for rep in reports for h in rep.get("hunts", [])]
        strikes = [h for rep in reports for h in rep.get("strikes", [])]
        spacing = [w.get("spacing") for w in watch if w.get("spacing") is not None]
        damage = [w.get("damage_per_unit") for w in watch if w.get("damage_per_unit") is not None]
        out[name] = {
            "enemy_spot_seconds": round(mean(t["enemy_spot_seconds"] for t in totals), 1),
            "enemy_spot_stalled": round(mean(t["enemy_spot_stalled"] for t in totals), 1),
            "blocked_seconds": round(mean(t["blocked_seconds"] for t in totals), 1),
            "raids": round(len(raids) / len(ok), 2),
            "kills_per_raid": round(mean(kills), 2) if kills else None,
            "raids_ended": ended,
            "intruder_seconds_10m": round(mean(e["intruder_seconds"] for e in early), 1),
            "intruder_stays_10m": round(stays / len(ok), 1),
            "intruders_killed_10m": round(sum(e["intruders_killed"] for e in early) / max(1, stays), 2),
            "mean_stay": round(mean(w.get("mean_stay") for w in watch if w.get("mean_stay") is not None), 1)
            if any(w.get("mean_stay") is not None for w in watch)
            else None,
            "extractors_lost_10m": round(mean(e["extractors_lost"] for e in early), 2),
            "extractors_lost": round(mean(t["extractors_lost"] for t in totals), 2),
            "extractors_end": round(mean(r[name]["extractors"] for r in ok), 1),
            "metal_income_end": round(mean(r[name]["metal_income"] for r in ok), 1),
            "enemy_extractors_killed_per_min": round(
                sum(r["watch"][other]["totals"]["extractors_lost"] for r in ok) / (sum(r["seconds"] for r in ok) / 60), 3
            ),
            "fronts_mean": round(mean(rep.get("fronts_mean", 0) for rep in reports), 2),
            "fronts_peak": round(mean(rep.get("fronts_peak", 0) for rep in reports), 1),
            "hunts": round(len(hunts) / len(ok), 2),
            "kills_per_hunt": round(mean(h.get("kills", 0) for h in hunts), 2) if hunts else None,
            "strikes": round(len(strikes) / len(ok), 2),
            "kills_per_strike": round(mean(h.get("kills", 0) for h in strikes), 2) if strikes else None,
            "spacing": round(mean(spacing), 2) if spacing else None,
            "damage_per_unit_second": round(mean(damage), 3) if damage else None,
        }
    out["a_points"] = round(mean(points(r, "a") for r in ok), 3)
    out["a_wins"] = sum(1 for r in ok if r.get("reason") == "commander" and r.get("winner") == "a")
    out["b_wins"] = sum(1 for r in ok if r.get("reason") == "commander" and r.get("winner") == "b")
    return out


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--a", default="sim_barb")
    parser.add_argument("--b", default="raider")
    parser.add_argument("--games", type=int, default=8)
    parser.add_argument("--seconds", type=int, default=900)
    parser.add_argument("--seed", type=int, default=11)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--out")
    parser.add_argument("--summarise", nargs="*")
    args = parser.parse_args()
    if args.summarise:
        results = []
        for path in args.summarise:
            results += [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
        print(json.dumps(summarise(results), indent=1))
        return
    todo = matches(side(args.a), side(args.b), args.games, args.seconds, args.seed)
    out = Path(args.out) if args.out else None
    if out is not None:
        out.parent.mkdir(parents=True, exist_ok=True)

    def on_result(result: dict[str, Any]) -> None:
        result.pop("timeline", None)
        if out is not None:
            with out.open("a") as handle:
                handle.write(json.dumps(result) + "\n")
        print(
            result.get("match", {}).get("preset"),
            result.get("winner"),
            result.get("reason"),
            result.get("seconds"),
            result.get("error", ""),
            flush=True,
        )

    results = arena.play_many(todo, workers=args.workers, on_result=on_result)
    print(json.dumps(summarise(results), indent=1))


if __name__ == "__main__":
    main()
