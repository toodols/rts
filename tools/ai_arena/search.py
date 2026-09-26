"""The search for the strongest AI profile: CMA-ES (cmaes.py) over the profile's numbers (profiles.py), each candidate
scored by the points it takes off a pool of opponents in arena matches (arena.py).

    python tools/ai_arena/search.py --run runs/search1 [--hours 10] [--line bot|vehicle] [--maps a,b,c] ...

The pool is the named profiles (shared/ai_profiles.luau's) and a hall of fame of the search's own champions, so
that a candidate is not rewarded for beating only what the search has already left behind. Every candidate in a
generation plays the same scenarios (map, seed, line, opponent), each from both starts, so the differences between
them are not luck of the draw. Everything is written to the run's folder as it happens: `matches.jsonl` (every
match), `generations.jsonl` (each generation's summary) and `checkpoint.json`, which a run picks up from if it is
started again with the same --run.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
from pathlib import Path
from typing import Any

import arena
import profiles
import scoring
from cmaes import CMAES


def opponent_side(opponent: Any) -> Any:
    """An opponent as a duel's side: a named profile, or a champion's overrides over default."""
    return opponent if isinstance(opponent, str) else opponent["overrides"]


def opponent_name(opponent: Any) -> str:
    return opponent if isinstance(opponent, str) else opponent["name"]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run", required=True, help="folder for this run's logs and checkpoint")
    parser.add_argument("--hours", type=float, default=10)
    parser.add_argument("--population", type=int, default=12)
    parser.add_argument("--scenarios", type=int, default=12, help="scenarios per candidate per generation")
    parser.add_argument("--seconds", type=int, default=900, help="game time a match may run to")
    parser.add_argument("--sigma", type=float, default=0.2)
    parser.add_argument("--workers", type=int, default=os.cpu_count() or 8)
    parser.add_argument("--line", choices=["bot", "vehicle"], help="play only this line")
    parser.add_argument("--maps", help="comma-separated maps instead of the usual pool")
    parser.add_argument("--hall", type=int, default=4, help="how many of its champions the pool keeps")
    parser.add_argument("--root", help="play the game's source from this checkout instead of this one")
    parser.add_argument("--seed", type=int, default=1)
    options = parser.parse_args()

    run = Path(options.run)
    if not run.is_absolute():
        run = Path(__file__).resolve().parent / run
    run.mkdir(parents=True, exist_ok=True)
    checkpoint_path = run / "checkpoint.json"
    maps = options.maps.split(",") if options.maps else scoring.MAPS
    lines = [options.line] if options.line else ["bot", "vehicle"]

    if checkpoint_path.exists():
        saved = json.loads(checkpoint_path.read_text())
        es = CMAES.restore(saved["es"])
        hall: list[dict[str, Any]] = saved["hall"]
        rng = random.Random()
        rng.setstate(tuple(saved["rng"][:1]) + (tuple(saved["rng"][1]),) + tuple(saved["rng"][2:]))
        games_played = saved["games_played"]
        print(f"resuming at generation {es.generation}, {games_played} games so far", flush=True)
    else:
        es = CMAES(profiles.encode({}), options.sigma, options.population, options.seed)
        hall = []
        rng = random.Random(options.seed)
        games_played = 0

    deadline = time.time() + options.hours * 3600
    while time.time() < deadline:
        generation = es.generation
        started = time.time()
        # every named profile, as shared/ai_profiles.luau has them, and the latest of the hall of fame
        pool: list[Any] = list(profiles.names()) + hall[-options.hall :]
        scenarios = scoring.scenarios(options.scenarios, maps, lines, rng)
        for index, scenario in enumerate(scenarios):
            scenario["opponent"] = pool[(index + generation) % len(pool)]
        points_list = es.ask()
        candidates = [profiles.decode(point) for point in points_list]
        # the mean itself is played too, for a steadier read of how the search is doing than its best sample
        mean_candidate = profiles.decode(list(es.mean))
        everyone = candidates + [mean_candidate]
        jobs = []
        owners = []
        for which, candidate in enumerate(everyone):
            for scenario_index, scenario in enumerate(scenarios):
                opponent = opponent_side(scenario["opponent"])
                for match in scoring.duels(candidate, opponent, [scenario], options.seconds, root=options.root):
                    jobs.append(match)
                    owners.append((which, scenario_index))

        results = arena.play_many(jobs, workers=options.workers)
        games_played += len(results)
        scores = [[0.0, 0] for _ in everyone]
        by_opponent: dict[str, list[float]] = {}
        failures = 0
        with open(run / "matches.jsonl", "a") as log:
            for (which, scenario_index), result in zip(owners, results):
                if not result.get("ok"):
                    failures += 1
                    log.write(json.dumps({"generation": generation, "error": result.get("error"), "match": result.get("match")}) + "\n")
                    continue
                got = scoring.points(result, "a")
                scores[which][0] += got
                scores[which][1] += 1
                if which == len(everyone) - 1:
                    name = opponent_name(scenarios[scenario_index]["opponent"])
                    by_opponent.setdefault(name, []).append(got)
                slim = {key: value for key, value in result.items() if key not in ("match",)}
                slim["opponent"] = opponent_name(scenarios[scenario_index]["opponent"])
                slim["candidate"] = which
                slim["generation"] = generation
                slim["overrides"] = everyone[which]
                log.write(json.dumps(slim) + "\n")
        fitness = [total / count if count > 0 else 0.0 for total, count in scores]
        es.tell(points_list, [-value for value in fitness[:-1]])

        best = max(range(len(candidates)), key=lambda index: fitness[index])
        # the mean goes into the hall of fame when it does well, its best sample otherwise
        champion = mean_candidate if fitness[-1] >= fitness[best] - 0.05 else candidates[best]
        hall.append({"name": f"g{generation}", "overrides": champion, "fitness": max(fitness[-1], fitness[best])})
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
            "mean_profile": mean_candidate,
            "best_profile": candidates[best],
            "pool": [opponent_name(opponent) for opponent in pool],
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
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    main()
