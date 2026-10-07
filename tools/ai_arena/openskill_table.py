"""OpenSkill ratings of AI profiles from arena duels: every game in the given result files (evaluate.py's --out,
JSON lines), each a one-on-one, rated with Weng-Lin's Plackett-Luce model (the `openskill` package's default model,
written out here so nothing needs installing) from mu 25, sigma 25/3, beta 25/6 and tau 25/300. A game won by killing
the commander is a win; one that reached the time limit is won by whoever was ahead on scoring.points, and a dead
level one is a draw. An online rating depends on the order of the games, so it is the mean over many shuffles.

    python tools/ai_arena/openskill_table.py runs/rr_barb.jsonl runs/sim_eval.jsonl --names @runs/names.json

Each side is named by its profile's name, or by --names, a JSON map from the side's JSON (as in the match) to a
name, for sides given as overrides. The table is sorted by the displayed rating, OS = mu - sigma.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import sys
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scoring import points  # noqa: E402

MU = 25.0
SIGMA = 25.0 / 3
BETA = SIGMA / 2
TAU = MU / 300
KAPPA = 0.0001


def rate(ratings: dict[str, list[float]], first: str, second: str, outcome: float) -> None:
    """One game: `outcome` 1 if `first` won, 0 if `second` did, 0.5 for a draw (Plackett-Luce, two teams of one)."""
    teams = [first, second]
    ranks = [0, 1] if outcome > 0.5 else [1, 0] if outcome < 0.5 else [0, 0]
    for name in teams:
        mu, sigma = ratings[name]
        ratings[name] = [mu, math.sqrt(sigma * sigma + TAU * TAU)]
    c = math.sqrt(sum(ratings[name][1] ** 2 + BETA * BETA for name in teams))
    exps = [math.exp(ratings[name][0] / c) for name in teams]
    counts = [sum(1 for r in ranks if r == rank) for rank in ranks]
    sums = [sum(exps[i] for i in range(2) if ranks[i] >= ranks[q]) for q in range(2)]
    updates = []
    for i, name in enumerate(teams):
        mu, sigma = ratings[name]
        omega = delta = 0.0
        for q in range(2):
            if ranks[q] > ranks[i]:
                continue
            quotient = exps[i] / sums[q]
            omega += ((1 - quotient) if i == q else -quotient) / counts[q]
            delta += quotient * (1 - quotient) / counts[q]
        gamma = sigma / c
        omega *= sigma * sigma / c
        delta *= gamma * sigma * sigma / (c * c)
        updates.append([mu + omega, sigma * math.sqrt(max(1 - delta, KAPPA))])
    for name, update in zip(teams, updates):
        ratings[name] = update


def side_name(side: dict[str, Any], names: dict[str, str]) -> str:
    key = json.dumps(side, sort_keys=True)
    if key in names:
        return names[key]
    # the neural network (tools/nn_ai) by the network playing, and the Rust AI
    if side.get("engine") == "nn":
        return side.get("name") or side.get("policy") or "nn"
    if side.get("engine") == "rust":
        return "rust"
    if side.get("overrides"):
        return side.get("profile", "default") + "+" + json.dumps(side["overrides"], sort_keys=True)
    return side.get("profile", "default")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="+")
    parser.add_argument("--names", help="JSON map (or @file) from a side's JSON to its name")
    parser.add_argument("--entrants", help="a round robin's entrants file ({name: profile}), to name its sides by")
    parser.add_argument("--shuffles", type=int, default=200)
    parser.add_argument("--only", help="comma-separated names to keep in the table (all games still count)")
    options = parser.parse_args()
    names: dict[str, str] = {}
    if options.names:
        text = Path(options.names[1:]).read_text() if options.names.startswith("@") else options.names
        names = {json.dumps(json.loads(k), sort_keys=True): v for k, v in json.loads(text).items()}

    if options.entrants:
        for name, profile in json.loads(Path(options.entrants).read_text()).items():
            if isinstance(profile, dict):
                names[json.dumps({"profile": "default", "overrides": profile}, sort_keys=True)] = name

    games: list[tuple[str, str, float]] = []
    seen: set[str] = set()
    for path in options.files:
        for line in open(path):
            if not line.strip():
                continue
            result = json.loads(line)
            if not result.get("ok"):
                continue
            key = json.dumps(result["match"], sort_keys=True)
            if key in seen:
                continue
            seen.add(key)
            a = side_name(result["match"]["a"], names)
            b = side_name(result["match"]["b"], names)
            games.append((a, b, points(result, "a")))

    rng = random.Random(1)
    totals: dict[str, list[float]] = {}
    record: dict[str, list[float]] = {}
    for a, b, p in games:
        for name, won in ((a, p), (b, 1 - p)):
            entry = record.setdefault(name, [0, 0, 0, 0])
            entry[0] += 1
            entry[1] += 1 if won > 0.5 else 0
            entry[2] += 1 if won < 0.5 else 0
            entry[3] += won
    for _ in range(options.shuffles):
        order = games[:]
        rng.shuffle(order)
        ratings: dict[str, list[float]] = {name: [MU, SIGMA] for name in record}
        for a, b, p in order:
            rate(ratings, a, b, p)
        for name, (mu, sigma) in ratings.items():
            total = totals.setdefault(name, [0.0, 0.0])
            total[0] += mu
            total[1] += sigma
    rows = []
    for name, (mu, sigma) in totals.items():
        mu /= options.shuffles
        sigma /= options.shuffles
        rows.append((mu - sigma, mu, sigma, name))
    keep = set(options.only.split(",")) if options.only else None
    print(f"{len(games)} games")
    print(f"{'profile':28} {'OS':>6} {'mu':>6} {'sigma':>6}  games  won  lost  mean points")
    for os_, mu, sigma, name in sorted(rows, reverse=True):
        if keep is not None and name not in keep:
            continue
        g, w, l, pts = record[name]
        print(f"{name[:28]:28} {os_:6.2f} {mu:6.2f} {sigma:6.2f}  {g:5}  {w:3}  {l:4}  {pts / g:.3f}")


if __name__ == "__main__":
    main()
