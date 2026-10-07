"""The search for the Rust AI's best numbers: CMA-ES (tools/ai_arena/cmaes.py) over every tunable number the Rust AI
has (`rust_ai --schema`, src/params.rs), each candidate scored by the points it takes off a pool of opponents in arena
matches: the server/ai profiles (shared/ai_profiles.luau) and a hall of fame of the search's own champions.

    python tools/rust_ai/search.py --run runs/search1 [--hours 10] [--line bot|vehicle] [--maps a,b] [--from p.json]

Each number is searched over its range from the schema, mapped onto the unit cube. Every candidate in a generation
plays the same scenarios (map, seed, line, opponent), each from both starts. The executable is copied into the run's
folder when the run starts, so rebuilding the Rust AI does not change what a run is searching. Everything goes to the
run's folder as it happens: `matches.jsonl`, `generations.jsonl`, `checkpoint.json` (a run started again with the same
--run picks up from it), and `best.json`, the search's mean as params, which `{"engine": "rust", "params": ...}` plays.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "ai_arena"))

import arena  # noqa: E402
import scoring  # noqa: E402
from cmaes import CMAES  # noqa: E402

EXE = HERE / "target" / "release" / "rust_ai.exe"
LUAU_POOL = ["raider", "swarm", "sim_barb", "barb", "default"]


def schema(exe: Path) -> list[dict[str, Any]]:
    out = subprocess.run([str(exe), "--schema"], capture_output=True, text=True, check=True).stdout
    return json.loads(out)


def encode(params: list[dict[str, Any]], values: dict[str, float]) -> list[float]:
    point = []
    for p in params:
        value = values.get(p["name"], p["default"])
        point.append(min(1.0, max(0.0, (value - p["min"]) / (p["max"] - p["min"]))))
    return point


def decode(params: list[dict[str, Any]], point: list[float]) -> dict[str, float]:
    values = {}
    for p, u in zip(params, point):
        u = min(1.0, max(0.0, float(u)))
        values[p["name"]] = round(p["min"] + u * (p["max"] - p["min"]), 4)
    return values


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", required=True, help="folder for this run's logs and checkpoint (under tools/rust_ai)")
    parser.add_argument("--hours", type=float, default=10)
    parser.add_argument("--population", type=int, default=14)
    parser.add_argument("--scenarios", type=int, default=5, help="scenarios per candidate per generation (two games each)")
    parser.add_argument("--seconds", type=int, default=1200, help="game time a match may run to")
    parser.add_argument("--sigma", type=float, default=0.15)
    parser.add_argument("--workers", type=int, default=os.cpu_count() or 8)
    parser.add_argument("--line", choices=["bot", "vehicle"], help="play only this line")
    parser.add_argument("--maps", help="comma-separated maps instead of the usual pool")
    parser.add_argument("--opponents", default=",".join(LUAU_POOL), help="comma-separated server/ai profiles to play")
    parser.add_argument("--hall", type=int, default=3, help="how many of its champions the pool keeps")
    parser.add_argument("--from", dest="start", help="a JSON file of params to start the search's mean at")
    parser.add_argument("--seed", type=int, default=1)
    options = parser.parse_args()

    run = Path(options.run)
    if not run.is_absolute():
        run = HERE / run
    run.mkdir(parents=True, exist_ok=True)
    exe = run / "rust_ai.exe"
    if not exe.exists():
        shutil.copy2(EXE, exe)
    params = schema(exe)
    checkpoint_path = run / "checkpoint.json"
    maps = options.maps.split(",") if options.maps else scoring.MAPS
    lines = [options.line] if options.line else ["bot", "vehicle"]
    luau_pool = options.opponents.split(",")

    if checkpoint_path.exists():
        saved = json.loads(checkpoint_path.read_text())
        es = CMAES.restore(saved["es"])
        hall: list[dict[str, Any]] = saved["hall"]
        rng = random.Random()
        rng.setstate(tuple(saved["rng"][:1]) + (tuple(saved["rng"][1]),) + tuple(saved["rng"][2:]))
        games_played = saved["games_played"]
        print(f"resuming at generation {es.generation}, {games_played} games so far", flush=True)
    else:
        start = json.loads(Path(options.start).read_text()) if options.start else {}
        es = CMAES(encode(params, start), options.sigma, options.population, options.seed)
        hall = []
        rng = random.Random(options.seed)
        games_played = 0

    def side(values: dict[str, float]) -> dict[str, Any]:
        return {"engine": "rust", "params": values, "exe": str(exe)}

    deadline = time.time() + options.hours * 3600
    while time.time() < deadline:
        generation = es.generation
        started = time.time()
        pool: list[Any] = list(luau_pool) + hall[-options.hall :]
        scenarios = scoring.scenarios(options.scenarios, maps, lines, rng)
        for index, scenario in enumerate(scenarios):
            scenario["opponent"] = pool[(index + generation) % len(pool)]
        points_list = es.ask()
        candidates = [decode(params, point) for point in points_list]
        mean_candidate = decode(params, list(es.mean))
        everyone = candidates + [mean_candidate]
        jobs = []
        owners = []
        for which, candidate in enumerate(everyone):
            for scenario_index, scenario in enumerate(scenarios):
                opponent = scenario["opponent"]
                other = opponent if isinstance(opponent, str) else side(opponent["params"])
                for match in scoring.duels(side(candidate), other, [scenario], options.seconds):
                    jobs.append(match)
                    owners.append((which, scenario_index))

        results = arena.play_many(jobs, workers=options.workers)
        games_played += len(results)
        scores = [[0.0, 0] for _ in everyone]
        by_opponent: dict[str, list[float]] = {}
        failures = 0
        with open(run / "matches.jsonl", "a") as log:
            for (which, scenario_index), result in zip(owners, results):
                opponent = scenarios[scenario_index]["opponent"]
                name = opponent if isinstance(opponent, str) else opponent["name"]
                if not result.get("ok"):
                    failures += 1
                    log.write(json.dumps({"generation": generation, "error": result.get("error"), "opponent": name}) + "\n")
                    continue
                got = scoring.points(result, "a")
                scores[which][0] += got
                scores[which][1] += 1
                if which == len(everyone) - 1:
                    by_opponent.setdefault(name, []).append(got)
                slim = {key: value for key, value in result.items() if key not in ("match",)}
                slim.update({"opponent": name, "candidate": which, "generation": generation,
                             "preset": result["match"]["preset"], "line": result["match"]["line"]})
                log.write(json.dumps(slim) + "\n")
        fitness = [total / count if count > 0 else 0.0 for total, count in scores]
        es.tell(points_list, [-value for value in fitness[:-1]])

        best = max(range(len(candidates)), key=lambda index: fitness[index])
        champion = mean_candidate if fitness[-1] >= fitness[best] - 0.05 else candidates[best]
        hall.append({"name": f"rust_g{generation}", "params": champion, "fitness": max(fitness[-1], fitness[best])})
        (run / "best.json").write_text(json.dumps(decode(params, list(es.mean)), indent=1, sort_keys=True))
        summary = {
            "generation": generation,
            "games": len(results),
            "failures": failures,
            "games_played": games_played,
            "minutes": round((time.time() - started) / 60, 1),
            "sigma": round(es.sigma, 4),
            "mean_fitness": round(fitness[-1], 4),
            "best_fitness": round(fitness[best], 4),
            "average_fitness": round(sum(fitness[:-1]) / len(candidates), 4),
            "mean_vs": {name: round(sum(v) / len(v), 3) for name, v in by_opponent.items()},
            "mean_params": mean_candidate,
            "best_params": candidates[best],
        }
        with open(run / "generations.jsonl", "a") as log:
            log.write(json.dumps(summary) + "\n")
        state = rng.getstate()
        checkpoint = {
            "es": es.state(),
            "hall": hall,
            "rng": [state[0], list(state[1]), state[2]],
            "games_played": games_played,
            "options": vars(options),
        }
        temporary = checkpoint_path.with_suffix(".tmp")
        temporary.write_text(json.dumps(checkpoint))
        temporary.replace(checkpoint_path)
        print(
            f"gen {generation}: mean {summary['mean_fitness']:.3f} best {summary['best_fitness']:.3f} "
            f"avg {summary['average_fitness']:.3f} sigma {summary['sigma']:.3f} vs {summary['mean_vs']} "
            f"({summary['minutes']} min, {games_played} games, {failures} failed)",
            flush=True,
        )


if __name__ == "__main__":
    main()
