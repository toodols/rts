"""The AI profile's numbers as the search sees them: each one's range, and how a point in the unit cube, where the
search works, maps to a profile's overrides (and back).

Everything about the numbers is shared/ai_profiles.luau's own: the default profile, each number's range and how it is
searched (evenly, on a log scale or in whole numbers), which end of its range stands for leaving it out (off, or no
limit), and which it may not be under. It is read through the arena's "profiles" mode the first time it is asked for
(`schema`), so importing this starts nothing.
"""

from __future__ import annotations

import functools
import math
from dataclasses import dataclass
from typing import Any

import arena


@dataclass(frozen=True)
class Param:
    name: str
    low: float
    high: float
    # "linear", "int", or "log" (a float searched on a log scale)
    scale: str
    # the end of the unit interval, "bottom" or "top", whose `absent_share` stands for leaving the number out
    absent_at: str | None
    absent_share: float
    # the number this one may not be under
    at_least: str | None


@functools.cache
def schema() -> dict[str, Any]:
    """shared/ai_profiles.luau's DEFAULT (its numbers and choices; what it leaves out is missing), RANGES, names, and
    the word an override leaves a number out with."""
    result = arena.play({"mode": "profiles"}, timeout=120)
    if not result.get("ok"):
        raise RuntimeError(f"the arena could not read the AI profiles: {result.get('error')}")
    return result


def default() -> dict[str, Any]:
    return schema()["default"]


def names() -> list[str]:
    return schema()["names"]


def absent() -> str:
    return schema()["absent"]


@functools.cache
def params() -> list[Param]:
    return [
        Param(
            name,
            spec["low"],
            spec["high"],
            spec["scale"],
            spec.get("absent_at"),
            spec.get("absent_share", 0.0),
            spec.get("at_least"),
        )
        for name, spec in sorted(schema()["ranges"].items())
    ]


def decode_one(param: Param, u: float) -> Any:
    """The value a coordinate `u` in [0, 1] stands for."""
    u = min(1.0, max(0.0, u))
    share = param.absent_share
    if param.absent_at == "top":
        if u > 1 - share:
            return absent()
        u = u / (1 - share)
    elif param.absent_at == "bottom":
        if u < share:
            return absent()
        u = (u - share) / (1 - share)
    if param.scale == "log":
        low = max(param.low, 1e-3)
        return round(math.exp(math.log(low) + u * (math.log(param.high) - math.log(low))), 3)
    value = param.low + u * (param.high - param.low)
    if param.scale == "int":
        return int(round(value))
    return round(value, 3)


def encode_one(param: Param, value: Any) -> float:
    """Where in [0, 1] a value sits (the middle of the stretch that leaves it out, for a number left out)."""
    share = param.absent_share
    if value is None or value == absent():
        return 1 - share / 2 if param.absent_at == "top" else share / 2
    if param.scale == "log":
        low = max(param.low, 1e-3)
        u = (math.log(max(value, low)) - math.log(low)) / (math.log(param.high) - math.log(low))
    else:
        u = (value - param.low) / (param.high - param.low)
    u = min(1.0, max(0.0, u))
    if param.absent_at == "top":
        return u * (1 - share)
    if param.absent_at == "bottom":
        return share + u * (1 - share)
    return u


def decode(point: list[float]) -> dict[str, Any]:
    """A profile's overrides from a point in the unit cube, each number no less than what it has to be at least."""
    values = {param.name: decode_one(param, u) for param, u in zip(params(), point)}
    for param in params():
        floor = param.at_least
        if floor is not None and values[param.name] != absent() and values[floor] != absent():
            values[param.name] = max(values[param.name], values[floor])
    return values


def encode(values: dict[str, Any]) -> list[float]:
    merged = dict(default())
    merged.update(values)
    return [encode_one(param, merged.get(param.name)) for param in params()]


def to_luau(name: str, values: dict[str, Any], comment: str = "") -> str:
    """A profile as a `with(DEFAULT, {...})` entry for shared/ai_profiles.luau, listing only what differs; a number
    left out is left out of it too, for `without`."""
    lines = [f"\t{name} = with(DEFAULT, {{", f'\t\tname = "{name}",']
    left_out = []
    for param in params():
        value = values.get(param.name, default().get(param.name))
        if value == default().get(param.name):
            continue
        if value is None or value == absent():
            left_out.append(f'"{param.name}"')
            continue
        text = str(value) if not isinstance(value, float) else f"{value:g}"
        lines.append(f"\t\t{param.name} = {text},")
    lines.append("\t}),")
    if left_out:
        lines[0] = f"\t{name} = with(without(DEFAULT, {{ {', '.join(left_out)} }}), {{"
    return "\n".join(lines)
