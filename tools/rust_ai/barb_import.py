"""Builds tools/rust_ai/data/barb.json: what BARb (BAR's computer player, CircuitAI's "barbarian" branch, with its
settings in Beyond-All-Reason's luarules/configs/BARb/stable/config/hard) says about the units this game has, keyed by
this game's def names, for the Rust AI to play by:

- each unit's roles, attributes, retreat health, and the modifiers on its threat and power (behaviour.json);
- each lab's income tiers and, for each tier, how likely it is to make each unit (factory.json);
- the response table: what each role is made in answer to (response.json);
- the quotas and threat modifiers (behaviour.json's "quota") and the economy's numbers (economy.json).

A def of this game is matched to BAR's by the `-- bar: <name>` line over it in src/shared/unit_defs. Run from the
repository's root:

    python tools/rust_ai/barb_import.py

It fetches BAR's files from GitHub (or reads them from --from, a folder holding behaviour.json, factory.json,
response.json and economy.json).
"""

from __future__ import annotations

import argparse
import json
import re
import urllib.request
from pathlib import Path

BAR = "https://raw.githubusercontent.com/beyond-all-reason/Beyond-All-Reason/master/luarules/configs/BARb/stable/config/hard"
FILES = ["behaviour.json", "factory.json", "response.json", "economy.json", "build_chain.json", "commander.json"]
ROOT = Path(__file__).resolve().parents[2]
OUT = Path(__file__).resolve().parent / "data" / "barb.json"


def loose_json(text: str) -> dict:
    """BARb's configs are JSON with // comments and trailing commas."""
    out = []
    in_string = False
    i = 0
    while i < len(text):
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            out.append(c)
        elif text.startswith("//", i):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
            continue
        else:
            out.append(c)
        i += 1
    cleaned = re.sub(r",(\s*[}\]])", r"\1", "".join(out))
    return json.loads(cleaned)


def our_names() -> dict[str, str]:
    """This game's def names by BAR's name, from the `-- bar:` lines."""
    found: dict[str, str] = {}
    for path in sorted((ROOT / "src" / "shared" / "unit_defs").glob("*.luau")):
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            match = re.match(r"\s*-- bar: (\w+)\s*$", line)
            if not match:
                continue
            for following in lines[index + 1 : index + 4]:
                name = re.match(r"\s*(\w+) = \{", following)
                if name:
                    found.setdefault(match.group(1), name.group(1))
                    break
    return found


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="source", help="a folder with BAR's config files, instead of fetching them")
    options = parser.parse_args()
    raw = {}
    for name in FILES:
        if options.source:
            raw[name] = (Path(options.source) / name).read_text(encoding="utf-8")
        else:
            with urllib.request.urlopen(f"{BAR}/{name}") as response:
                raw[name] = response.read().decode("utf-8")
    behaviour = loose_json(raw["behaviour.json"])
    factory = loose_json(raw["factory.json"])
    response = loose_json(raw["response.json"])
    economy = loose_json(raw["economy.json"])

    ours = our_names()
    units = {}
    for bar_name, ours_name in sorted(ours.items()):
        entry = behaviour["behaviour"].get(bar_name)
        if entry is None:
            continue
        entry = dict(entry)
        # a role or attribute given alone is a list of one
        for key in ("role", "attribute"):
            if isinstance(entry.get(key), str):
                entry[key] = [entry[key]]
        units[ours_name] = {"bar": bar_name, **entry}

    labs = {}
    for bar_name, lab in factory["factory"].items():
        ours_name = ours.get(bar_name)
        if ours_name is None:
            continue
        unit_list = lab.get("unit", [])
        tiers = {}
        for surface in ("land", "air", "water"):
            table = lab.get(surface)
            if table is None:
                continue
            tiers[surface] = []
            for tier_name in sorted(table, key=lambda t: int(t[4:])):
                weights = {}
                for bar_unit, weight in zip(unit_list, table[tier_name]):
                    if bar_unit in ours and weight > 0:
                        weights[ours[bar_unit]] = weight
                tiers[surface].append(weights)
        labs[ours_name] = {
            "bar": bar_name,
            "income_tier": lab.get("income_tier", []),
            "require_energy": lab.get("require_energy", False),
            "caretaker": lab.get("caretaker", 0),
            "tiers": tiers,
        }

    # each unit's weights in the BAR lab that makes it (its own), by tier, with that lab's income tiers: this game's
    # labs mix BAR's factions, so a lab's options are weighed each by its own BAR lab
    for bar_lab, lab in factory["factory"].items():
        unit_list = lab.get("unit", [])
        for position, bar_unit in enumerate(unit_list):
            ours_name = ours.get(bar_unit)
            if ours_name is None:
                continue
            entry = units.setdefault(ours_name, {"bar": bar_unit})
            if "tiers" in entry:
                continue
            tiers = {}
            for surface in ("land", "air", "water"):
                table = lab.get(surface)
                if table is None:
                    continue
                tiers[surface] = [table[t][position] for t in sorted(table, key=lambda t: int(t[4:]))]
            entry["tiers"] = tiers
            entry["income_tier"] = lab.get("income_tier", [])
            entry["native_lab"] = bar_lab

    build_chain = loose_json(raw["build_chain.json"])
    commander = loose_json(raw["commander.json"])
    eco = economy["economy"]

    # a BAR unit this game lacks stands for its other faction's twin when this game has that: the porcupine lists pair
    # the factions' defences index by index (armllt with corllt, and so on)
    twins: dict[str, str] = {}
    porc_sides = build_chain["porcupine"]["unit"]
    arm, cor = porc_sides.get("armada", []), porc_sides.get("cortex", [])
    for a, c in zip(arm, cor):
        twins.setdefault(a, c)
        twins.setdefault(c, a)

    def mapped(name: str) -> str | None:
        if name in ours:
            return ours[name]
        twin = twins.get(name)
        return ours.get(twin) if twin is not None else None

    # economy.json's generators for land, in its order (highest tech first, as BARb sorts them by cost), with
    # [limit_min, limit_max, metal_income, energy_income, score] (missing ones are BARb's defaults, -1)
    energy_land = []
    for bar_name, cond in eco["energy"]["land"].items():
        if mapped(bar_name) is not None:
            energy_land.append({"def": mapped(bar_name), "bar": bar_name, "cond": cond})

    # the porcupine: BARb's defender list per faction, by index, each index as whichever faction's unit this game has
    porc = build_chain["porcupine"]
    sides = porc["unit"]
    width = max(len(v) for v in sides.values())
    by_index = []
    for index in range(width):
        choices = []
        for side in ("cortex", "armada"):
            names = sides.get(side, [])
            if index < len(names) and mapped(names[index]) is not None and mapped(names[index]) not in choices:
                choices.append(mapped(names[index]))
        by_index.append(choices)
    porcupine = {
        "defenders": by_index,
        "land": porc.get("land", []),
        "prevent": porc.get("prevent", 1),
        "amount": porc.get("amount", {}),
        "point_range": porc.get("point_range", 600.0),
        "base": porc.get("base", []),
    }

    # build chains: what goes up after each kind of building, mapped (entries whose unit this game lacks are dropped)
    chains = {}
    for category, entries in build_chain["build_chain"].items():
        for bar_name, chain in entries.items():
            ours_name = mapped(bar_name)
            if ours_name is None:
                continue
            hubs = []
            for queue in chain.get("hub", []):
                steps = []
                for step in queue:
                    unit = mapped(step.get("unit", ""))
                    if unit is not None:
                        steps.append({**step, "unit": unit})
                if steps:
                    hubs.append(steps)
            chains[ours_name] = {"category": category, "porc": chain.get("porc", False), "energy": chain.get("energy"), "hub": hubs}

    factories = {}
    for bar_name, lab in factory["factory"].items():
        if mapped(bar_name) is not None:
            factories[mapped(bar_name)] = {
                "bar": bar_name,
                "importance": lab.get("importance", [1.0, 1.0]),
                "caretaker": lab.get("caretaker", 0),
                "require_energy": lab.get("require_energy", False),
            }

    commanders = {}
    for bar_name, info in commander["commander"]["unit"].items():
        if mapped(bar_name) is not None:
            commanders[mapped(bar_name)] = {"bar": bar_name, "hide": info.get("hide", {}), "assist_fac": info.get("assist_fac", 0)}

    out = {
        "source": BAR,
        "quota": behaviour.get("quota", {}),
        "retreat": behaviour.get("retreat", {}),
        "defence": behaviour.get("defence", {}),
        "units": units,
        "labs": labs,
        "factories": factories,
        "response": response["response"],
        "economy": {
            "factor": eco["energy"]["factor"],
            "buildpower": eco.get("buildpower"),
            "goal_exec": eco.get("goal_exec"),
            "mex_up": eco.get("mex_up"),
            "build_mod": eco.get("build_mod", 1000.0),
            "cluster_range": eco.get("cluster_range", 950.0),
            "mex_max": eco.get("mex_max", [2.0, True]),
            "ms_pull": eco.get("ms_pull", [[1.0, 0.0]]),
            "eps_step": eco.get("eps_step", 0.25),
            "excess": eco.get("excess", -1.0),
            "min_income": eco["energy"].get("min_income", 5.0),
            "cost_ratio": eco["energy"].get("cost_ratio", 0.05),
            "em_ratio": eco["energy"].get("em_ratio", 0.08),
            "energy_land": energy_land,
            # [newFacModM, newFacModE, facModM, facModE] (FactoryManager ReadConfig)
            "production": eco.get("production", [0.8, 0.8, 0.8, 0.8]),
            "assist": [mapped(n) for n in eco.get("assist", {}).values() if mapped(n) is not None],
        },
        "porcupine": porcupine,
        "build_chain": chains,
        "commanders": commanders,
        "select": factory.get("select", {}),
        "bar_names": {v: k for k, v in ours.items()},
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(out, indent=1, sort_keys=True) + "\n", encoding="utf-8", newline="\n")
    print(f"{len(units)} units, {len(labs)} labs -> {OUT}")


if __name__ == "__main__":
    main()
