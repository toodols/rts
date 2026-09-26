"""Which of the profile's numbers mattered, from a search's matches: every candidate a search played is a sample of
(numbers, points), and this fits the points on the numbers.

    python tools/ai_arena/analyse.py runs/search1 [--line bot|vehicle] [--opponent default]

For each number: its rank correlation with the points a candidate took, and its weight in a ridge regression of the
points on all the numbers together (in the search's unit-cube coordinates, standardised), with a second-order term
whose sign says whether the best value lies inside the range (negative) or at an end. Then the searches' last mean
and hall of fame as ai_profiles.luau entries.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

import profiles  # noqa: E402
from scoring import points  # noqa: E402


def rank(values: np.ndarray) -> np.ndarray:
    order = values.argsort(kind="stable")
    ranks = np.empty(len(values))
    ranks[order] = np.arange(len(values))
    return ranks


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run")
    parser.add_argument("--line", choices=["bot", "vehicle"])
    parser.add_argument("--opponent")
    parser.add_argument("--map")
    parser.add_argument("--from-generation", type=int, default=0)
    options = parser.parse_args()
    run = Path(options.run)
    if not run.is_absolute():
        run = Path(__file__).resolve().parent / run

    samples: dict[tuple[int, int], dict] = {}
    for line in open(run / "matches.jsonl"):
        record = json.loads(line)
        if "error" in record and "overrides" not in record:
            continue
        if record["generation"] < options.from_generation:
            continue
        if options.line and record.get("line") != options.line:
            continue
        if options.opponent and record.get("opponent") != options.opponent:
            continue
        if options.map and record.get("preset") != options.map:
            continue
        key = (record["generation"], record["candidate"])
        sample = samples.setdefault(key, {"overrides": record["overrides"], "points": []})
        sample["points"].append(points(record, "a"))

    keys = sorted(samples)
    x = np.array([profiles.encode(samples[key]["overrides"]) for key in keys])
    y = np.array([np.mean(samples[key]["points"]) for key in keys])
    weights = np.array([len(samples[key]["points"]) for key in keys], dtype=float)
    print(f"{len(keys)} candidates, {int(weights.sum())} games, mean points {np.average(y, weights=weights):.3f}")

    names = [param.name for param in profiles.params()]
    varied = x.std(axis=0) > 1e-9
    mean, spread = x.mean(axis=0), np.where(varied, x.std(axis=0), 1)
    z = (x - mean) / spread
    features = np.hstack([z, z**2 - 1])
    lam = 5.0
    w = weights / weights.mean()
    a = features.T @ (features * w[:, None]) + lam * np.eye(features.shape[1])
    coefficients = np.linalg.solve(a, features.T @ (w * (y - np.average(y, weights=w))))
    linear, curve = coefficients[: len(names)], coefficients[len(names) :]
    ry = rank(y)
    rows = []
    for index, name in enumerate(names):
        if not varied[index]:
            continue
        correlation = float(np.corrcoef(rank(x[:, index]), ry)[0, 1])
        rows.append((abs(linear[index]) + abs(curve[index]), name, correlation, linear[index], curve[index]))
    rows.sort(reverse=True)
    print(f"{'number':24} {'rank corr':>9} {'linear':>8} {'curve':>8}   (points per standard deviation)")
    for _, name, correlation, lin, cur in rows:
        print(f"{name:24} {correlation:9.3f} {lin:8.3f} {cur:8.3f}")

    checkpoint = run / "checkpoint.json"
    if checkpoint.exists():
        saved = json.loads(checkpoint.read_text())
        print("\nthe search's mean now:")
        print(profiles.to_luau("tuned", profiles.decode(saved["es"]["mean"])))
        print("\nits hall of fame, last few:")
        for entry in saved["hall"][-5:]:
            print(entry["name"], round(entry["fitness"], 3), json.dumps(entry["overrides"]))


if __name__ == "__main__":
    main()
