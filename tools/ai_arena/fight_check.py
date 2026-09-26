"""How well the AI's fight predictor (src/server/ai/combat_sim.luau) calls fights: many staged fights (arena.luau's "fight"
mode), each asked of the predictor before it is played and then played out in the real game, the two set side by side.

    python tools/ai_arena/fight_check.py --count 300 --workers 4 --out runs/fights.jsonl
    python tools/ai_arena/fight_check.py --out runs/fights.jsonl --report-only

The fights are drawn from families: first-tier ground against first-tier ground, second tier against second tier,
the two tiers mixed, ground attackers against ground with defences, aircraft against ground with some anti-air, and
aircraft against aircraft, each family's units worked out from the defs themselves (arena.luau's "defs" mode,
`families`). Each side is one to three kinds of unit bought with a budget of worth, the second side's
budget a random 0.5 to 2 times the first's, so most fights are not foregone. Results go to --out as they come in,
and a run that is stopped carries on from there.

The report says how often the predictor named the real winner (the side with the bigger share of its armed worth
left), over all fights and over the close ones (budgets within 1.5 times of each other), next to the plain rule the
AI used before it (the side worth more wins); and how far its remaining worth was from the real game's, as a share
of what each side started with.
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

MOST_PER_SIDE = 60


def load_defs() -> list[dict[str, Any]]:
    """Every def, as arena.luau's "defs" mode tells of it."""
    result = arena.play({"mode": "defs", "preset": "prairie", "seed": 1})
    assert result.get("ok"), result
    return result["defs"]


def families(defs: list[dict[str, Any]]) -> dict[str, list[str]]:
    """What each family's sides are made of, from the defs: armed ground units of the first and of the second tier that
    build nothing, armed defences that are not for aircraft, armed aircraft that build nothing, and whatever is armed
    to shoot aircraft down, on the ground or standing."""
    def pick(wanted: Any) -> list[str]:
        return sorted(entry["name"] for entry in defs if entry["armed"] and wanted(entry))

    def ground(tier: int) -> Any:
        return lambda e: (
            e["kind"] == "unit" and not e["air"] and not e["builder"] and e["speed"] > 0
            and e["category"] in ("bots", "vehicles") and e["tech_level"] == tier
        )

    return {
        "t1": pick(ground(1)),
        "t2": pick(ground(2)),
        "defences": pick(lambda e: e["kind"] == "building" and e["category"] == "defences" and not e["anti_air"]),
        "air": pick(lambda e: e["kind"] == "unit" and e["air"] and not e["builder"]),
        "anti_air_units": pick(lambda e: e["anti_air"] and e["kind"] == "unit" and not e["air"]),
        "anti_air_defences": pick(lambda e: e["anti_air"] and e["kind"] == "building"),
    }


def buy(rng: random.Random, pool: list[str], budget: float, powers: dict[str, float], kinds: int) -> list[dict]:
    """One to `kinds` kinds from `pool`, the budget split among them at random, at least one of each."""
    chosen = rng.sample(pool, min(len(pool), rng.randint(1, kinds)))
    weights = [rng.random() + 0.2 for _ in chosen]
    total = sum(weights)
    bought = []
    for name, weight in zip(chosen, weights):
        count = max(1, round(budget * weight / total / powers[name]))
        bought.append({"def": name, "count": count})
    # no more than MOST_PER_SIDE things a side
    things = sum(entry["count"] for entry in bought)
    if things > MOST_PER_SIDE:
        for entry in bought:
            entry["count"] = max(1, entry["count"] * MOST_PER_SIDE // things)
    return bought


def worth(side: list[dict], powers: dict[str, float]) -> float:
    return sum(entry["count"] * powers[entry["def"]] for entry in side)


def scenario(
    rng: random.Random, index: int, powers: dict[str, float], family_defs: dict[str, list[str]]
) -> dict[str, Any]:
    family = ["t1", "t2", "mixed", "defended", "air", "air_vs_air"][index % 6]
    ratio = math.exp(rng.uniform(math.log(0.5), math.log(2)))
    match: dict[str, Any] = {"mode": "fight", "preset": "prairie", "seed": 1, "seconds": 90, "family": family,
                             "distance": rng.randint(100, 160)}
    if family == "t1":
        budget = rng.uniform(300, 2500)
        match["a"] = buy(rng, family_defs["t1"], budget, powers, 3)
        match["b"] = buy(rng, family_defs["t1"], budget * ratio, powers, 3)
    elif family == "t2":
        budget = rng.uniform(2000, 9000)
        match["a"] = buy(rng, family_defs["t2"], budget, powers, 3)
        match["b"] = buy(rng, family_defs["t2"], budget * ratio, powers, 3)
    elif family == "mixed":
        budget = rng.uniform(1000, 6000)
        match["a"] = buy(rng, family_defs["t1"] + family_defs["t2"], budget, powers, 3)
        match["b"] = buy(rng, family_defs["t1"] + family_defs["t2"], budget * ratio, powers, 3)
    elif family == "defended":
        budget = rng.uniform(600, 6000)
        match["a"] = buy(rng, family_defs["t1"] + family_defs["t2"], budget, powers, 3)
        share = rng.uniform(0.4, 1.0)
        match["b_defences"] = buy(rng, family_defs["defences"], budget * ratio * share, powers, 2)
        if share < 0.95:
            match["b"] = buy(rng, family_defs["t1"], budget * ratio * (1 - share), powers, 2)
        match["spread"] = rng.randint(8, 30)
    elif family == "air":
        budget = rng.uniform(600, 6000)
        match["a"] = buy(rng, family_defs["air"], budget, powers, 2)
        share = rng.uniform(0.2, 0.8)
        match["b"] = buy(rng, family_defs["anti_air_units"], budget * ratio * share, powers, 2) + buy(
            rng, family_defs["t1"], budget * ratio * (1 - share), powers, 2)
        if rng.random() < 0.4:
            match["b_defences"] = buy(rng, family_defs["anti_air_defences"], budget * ratio * 0.3, powers, 1)
    else:
        budget = rng.uniform(500, 5000)
        match["a"] = buy(rng, family_defs["air"], budget, powers, 2)
        match["b"] = buy(rng, family_defs["air"], budget * ratio, powers, 2)
    match["index"] = index
    return match


def key(match: dict[str, Any]) -> str:
    return json.dumps(match, sort_keys=True)


def report(results: list[dict[str, Any]]) -> None:
    ok = [r for r in results if r.get("ok")]
    if "--dump" in sys.argv:
        for r in ok:
            if r["predicted"].get("winner") != r["real"].get("winner"):
                m = r["match"]
                print(m["family"], "a", m.get("a"), m.get("a_defences", ""), "b", m.get("b"), m.get("b_defences", ""),
                      "real", r["real"]["margin"], r["real"]["worth"], "pred", r["predicted"]["margin"],
                      r["predicted"]["worth"])
    print(f"{len(ok)} fights played ({len(results) - len(ok)} failed)")

    def summarise(label: str, rows: list[dict[str, Any]]) -> None:
        if not rows:
            return
        called = sum(1 for r in rows if r["predicted"].get("winner") == r["real"].get("winner"))
        naive = sum(
            1 for r in rows
            if ("a" if r["real"]["start_worth"]["a"] >= r["real"]["start_worth"]["b"] else "b") == r["real"].get("winner")
        )
        errors = []
        for r in rows:
            for side in ("a", "b"):
                start = r["real"]["start_worth"][side]
                if start > 0:
                    errors.append(abs(r["predicted"]["worth"][side] - r["real"]["worth"][side]) / start)
        margin_error = sum(abs(r["predicted"]["margin"] - r["real"]["margin"]) for r in rows) / len(rows)
        ms = sorted(r["predicted"]["ms"] for r in rows)
        print(
            f"  {label:28} n={len(rows):4}  winner {called / len(rows):6.1%}  (worth rule {naive / len(rows):6.1%})"
            f"  worth left off by {sum(errors) / len(errors):5.1%} of start  margin off by {margin_error:.3f}"
            f"  predict ms median {ms[len(ms) // 2]:.2f} max {ms[-1]:.2f}"
        )

    # a fight that is not foregone: the budgets within 2.5 times of each other, and one that both sides survive
    # nothing of is left out of "decided"
    rows = [r for r in ok if r["real"].get("winner") is not None]
    summarise("all", rows)
    close = [r for r in rows if max(r["real"]["start_worth"].values()) <= 1.5 * min(r["real"]["start_worth"].values())]
    summarise("close (worth within 1.5x)", close)
    nontrivial = [r for r in rows if abs(r["real"]["margin"]) < 0.9 or r in close]
    summarise("non-trivial", nontrivial)
    by_family: dict[str, list[dict[str, Any]]] = {}
    for r in rows:
        by_family.setdefault(r["match"]["family"], []).append(r)
    for family, members in sorted(by_family.items()):
        summarise(family, members)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--count", type=int, default=300)
    parser.add_argument("--seed", type=int, default=7)
    parser.add_argument("--random-seed", type=int,
                        help="play the same fights with the game's chance rolled from this, to see how far the real game "
                        "agrees with itself")
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--out", required=True)
    parser.add_argument("--report-only", action="store_true")
    parser.add_argument("--dump", action="store_true", help="list the fights the predictor got wrong")
    parser.add_argument("--repredict", action="store_true",
                        help="ask the predictor again about the fights in --out, as it is now, without playing them")
    options = parser.parse_args()

    out_path = Path(options.out)
    done: dict[str, dict[str, Any]] = {}
    if out_path.exists():
        for line in open(out_path):
            if line.strip():
                result = json.loads(line)
                if result.get("ok"):
                    done[key(result["match"])] = result
    if options.report_only:
        report(list(done.values()))
        return
    if options.repredict:
        results = list(done.values())
        ask = {"mode": "predict", "preset": "prairie", "seed": 1, "fights": [r["start"] for r in results]}
        answer = arena.play(ask)
        assert answer.get("ok"), answer.get("error")
        for result, prediction in zip(results, answer["predictions"]):
            prediction["ms"] = answer["ms_each"]
            result["predicted"] = prediction
        # kept beside --out, for looking into
        Path(str(out_path) + ".predicted.json").write_text(json.dumps([r["predicted"] for r in results]))
        report(results)
        return

    defs = load_defs()
    powers = {entry["name"]: entry["power"] for entry in defs}
    family_defs = families(defs)
    rng = random.Random(options.seed)
    matches = [scenario(rng, index, powers, family_defs) for index in range(options.count)]
    if options.random_seed is not None:
        for match in matches:
            match["random_seed"] = options.random_seed
    todo = [m for m in matches if key(m) not in done]
    print(f"{len(matches) - len(todo)} of {len(matches)} fights already played", file=sys.stderr)
    with open(out_path, "a") as out:
        def keep(result: dict[str, Any]) -> None:
            out.write(json.dumps(result) + "\n")
            out.flush()

        for result in arena.play_many(todo, workers=options.workers, on_result=keep):
            done[key(result["match"])] = result
    report([done[key(m)] for m in matches if key(m) in done])


if __name__ == "__main__":
    main()
