"""What the tools that play many duels share, none of which needs the game: the maps they play on, how a side and a
pair of duels is written for the arena, and what a duel was worth to a side. Importing this starts nothing.
"""

from __future__ import annotations

import random
from typing import Any

# Land maps where a bot and a vehicle can each walk from one start to the other (arena.luau's "reach" mode), with the
# starts 330 to 650 studs apart, so that a game is decided in reasonable time; see README.md. Run the arena's "maps"
# and "reach" modes to choose again as maps come and go.
MAPS = [
    "highlands",
    "continents",
    "koth",
    "gale",
    "great_divide",
    "altair_crossing",
    "faster_than_light",
    "pinewood_derby",
    "aurelia",
    "canis_river",
    "center_command",
    "last_stand",
    "mesas",
    "canyons",
]


def strength(side: dict[str, Any]) -> float:
    """What a side has at the end, and what it took off the other: the tie-break for a game that runs out of time."""
    return side["total_worth"] + side["destroyed"]


def points(result: dict[str, Any], side: str) -> float:
    """What a match was worth to `side`: 1 for a win, 0 for a loss, and for a game that ran out of time 0.1 to 0.9 by
    how far ahead it was (`strength`)."""
    other = "b" if side == "a" else "a"
    if result.get("reason") == "commander":
        winner = result.get("winner")
        return 0.5 if winner is None else (1.0 if winner == side else 0.0)
    mine, theirs = strength(result[side]), strength(result[other])
    share = mine / (mine + theirs) if mine + theirs > 0 else 0.5
    return 0.5 + 0.8 * (share - 0.5)


def side(profile: Any) -> dict[str, Any]:
    """A profile as a duel's side: a named one ("default"), a side already (with "profile" or "overrides"), or a
    table of overrides over default."""
    if isinstance(profile, str):
        return {"profile": profile}
    # the Rust AI (tools/rust_ai): {"engine": "rust", "params": {...}}
    if "profile" in profile or "overrides" in profile or "engine" in profile:
        return profile
    return {"profile": "default", "overrides": profile}


def scenarios(count: int, maps: list[str], lines: list[str], rng: random.Random) -> list[dict[str, Any]]:
    """`count` scenarios to play: a map of `maps`, a seed and a line of `lines` taken in turn."""
    return [
        {"map": rng.choice(maps), "seed": rng.randrange(1, 1_000_000), "line": lines[index % len(lines)]}
        for index in range(count)
    ]


def duels(
    a: Any,
    b: Any,
    plays: list[dict[str, Any]],
    seconds: int,
    every: int | None = None,
    root: str | None = None,
) -> list[dict[str, Any]]:
    """The duels of `a` against `b` (profiles, as `side` takes them) in each of `plays`, each from both starts."""
    matches = []
    for play in plays:
        for swap in (False, True):
            match: dict[str, Any] = {
                "mode": "duel",
                "preset": play["map"],
                "seed": play["seed"],
                "line": play["line"],
                "seconds": seconds,
                "swap": swap,
                "a": side(a),
                "b": side(b),
            }
            if every is not None:
                match["every"] = every
            if root is not None:
                match["root"] = root
            matches.append(match)
    return matches
