"""The live dashboard of the Rust AI's evaluations and training runs: tools/ai_arena/runs/live/dashboard.html in the main
checkout (what the user keeps open), written again every few seconds from the runs listed in sources.json beside it.

    python tools/rust_ai/live.py [--every 15] [--once]

sources.json is a list of runs, each {"label": ..., "kind": "eval", "path": <evaluate.py --out file>, "expected": n} or
{"label": ..., "kind": "search", "path": <search.py --run folder>}; relative paths are from the repository root the
file names. A run is added to it (`add`) as it starts, and the page picks it up on its next write:

    python tools/rust_ai/live.py add eval "rust vs sim_barb, 10 full games" tools/rust_ai/runs/port/batch6.jsonl 10

The page shows the games being played now, the OpenSkill ratings (as tools/ai_arena/openskill_table.py rates them) and
head to head of every evaluation, the latest games, and for each training run its generations: fitness of the search's
mean, its best and its average candidate, sigma, and how the mean did against each opponent.
"""

from __future__ import annotations

import argparse
import html
import json
import random
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(REPO / "tools" / "ai_arena"))

from openskill_table import MU, SIGMA, rate  # noqa: E402
from scoring import points, strength  # noqa: E402

# the page the user keeps open, in the main checkout whatever tree this runs from
MAIN = Path(r"C:\Users\Ethan\Desktop\rts")
LIVE = MAIN / "tools" / "ai_arena" / "runs" / "live"
PAGE = LIVE / "dashboard.html"
SOURCES = LIVE / "sources.json"

STYLE = """
:root { --bg:#f6f7f9; --panel:#fff; --text:#1d2330; --muted:#667085; --line:#e4e7ec; --accent:#3563e9; --good:#1f9d55; --bad:#d64545; --best:#1f9d55; --avg:#98a2b3; }
@media (prefers-color-scheme: dark) { :root { --bg:#11141a; --panel:#1a1f28; --text:#e7eaf0; --muted:#98a2b3; --line:#2a3140; --accent:#7c9cff; --good:#4cc38a; --bad:#ff7b7b; --best:#4cc38a; --avg:#667085; } }
body { margin:0; background:var(--bg); color:var(--text); font:14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width:1200px; margin:0 auto; padding:20px 16px 40px; }
h1 { font-size:20px; margin:0 0 4px; } h2 { font-size:15px; margin:24px 0 8px; } h3 { font-size:14px; margin:4px 0 8px; }
.meta { color:var(--muted); }
section { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:12px 14px; overflow-x:auto; margin-bottom:10px; }
table { border-collapse:collapse; width:100%; }
th, td { text-align:left; padding:5px 8px; border-bottom:1px solid var(--line); white-space:nowrap; }
th { color:var(--muted); font-weight:600; font-size:12px; }
td.num { text-align:right; font-variant-numeric:tabular-nums; }
.bar { display:inline-block; width:60px; height:6px; background:var(--line); border-radius:3px; vertical-align:middle; margin-left:6px; }
.bar span { display:block; height:100%; background:var(--accent); border-radius:3px; }
.note { color:var(--muted); font-size:12px; margin-top:8px; }
.win { color:var(--good); } .loss { color:var(--bad); }
svg text { fill:var(--muted); font-size:11px; }
.legend span { margin-right:14px; } .swatch { display:inline-block; width:10px; height:3px; vertical-align:middle; margin-right:4px; }
"""


def esc(value: Any) -> str:
    return html.escape(str(value))


def resolve(path: str) -> Path:
    p = Path(path)
    return p if p.is_absolute() else REPO / p


def read_sources() -> list[dict[str, Any]]:
    if not SOURCES.exists():
        return []
    try:
        return json.loads(SOURCES.read_text())
    except (OSError, json.JSONDecodeError):
        return []


def add_source(kind: str, label: str, path: str, expected: int | None) -> None:
    LIVE.mkdir(parents=True, exist_ok=True)
    sources = [s for s in read_sources() if s.get("label") != label]
    entry: dict[str, Any] = {"label": label, "kind": kind, "path": str(resolve(path))}
    if expected is not None:
        entry["expected"] = expected
    sources.append(entry)
    SOURCES.write_text(json.dumps(sources, indent=1))


def lines_of(path: Path) -> list[dict[str, Any]]:
    out = []
    if not path.exists():
        return out
    for line in path.read_text().splitlines():
        if line.strip():
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return out


def side_label(side: dict[str, Any], label: str) -> str:
    if side.get("engine") == "rust":
        return label
    return side.get("profile", "default") + ("+" + json.dumps(side["overrides"], sort_keys=True) if side.get("overrides") else "")


def playing_now() -> int:
    try:
        out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq lune.exe", "/NH"], capture_output=True, text=True, timeout=10).stdout
        return sum(1 for line in out.splitlines() if line.lower().startswith("lune.exe"))
    except (OSError, subprocess.SubprocessError):
        return 0


def ratings_table(games: list[tuple[str, str, float]]) -> list[tuple[float, float, float, str, list[float]]]:
    record: dict[str, list[float]] = {}
    for a, b, p in games:
        for name, won in ((a, p), (b, 1 - p)):
            entry = record.setdefault(name, [0, 0, 0, 0, 0])
            entry[0] += 1
            entry[1] += 1 if won > 0.5 else 0
            entry[2] += 1 if won < 0.5 else 0
            entry[3] += 1 if won == 0.5 else 0
            entry[4] += won
    totals: dict[str, list[float]] = {name: [0.0, 0.0] for name in record}
    rng = random.Random(1)
    shuffles = 100
    for _ in range(shuffles):
        order = games[:]
        rng.shuffle(order)
        ratings = {name: [MU, SIGMA] for name in record}
        for a, b, p in order:
            if a != b:
                rate(ratings, a, b, p)
        for name, (mu, sigma) in ratings.items():
            totals[name][0] += mu / shuffles
            totals[name][1] += sigma / shuffles
    rows = [(mu - sigma, mu, sigma, name, record[name]) for name, (mu, sigma) in totals.items()]
    return sorted(rows, reverse=True)


def chart(gens: list[dict[str, Any]]) -> str:
    if not gens:
        return ""
    width, height, pad = 720, 180, 28
    series = [("mean_fitness", "var(--accent)"), ("best_fitness", "var(--best)"), ("average_fitness", "var(--avg)")]
    values = [g[k] for g in gens for k, _ in series if k in g]
    lo, hi = min(values + [0.4]), max(values + [0.6])
    span = max(hi - lo, 1e-6)
    n = max(len(gens) - 1, 1)

    def xy(i: int, v: float) -> tuple[float, float]:
        return pad + (width - 2 * pad) * i / n, height - pad - (height - 2 * pad) * (v - lo) / span

    parts = [f'<svg viewBox="0 0 {width} {height}" width="100%" role="img" aria-label="fitness by generation">']
    for v in (lo, (lo + hi) / 2, hi):
        _, y = xy(0, v)
        parts.append(f'<line x1="{pad}" x2="{width - pad}" y1="{y:.1f}" y2="{y:.1f}" stroke="var(--line)"/>')
        parts.append(f'<text x="2" y="{y + 4:.1f}">{v:.2f}</text>')
    _, half = xy(0, 0.5)
    if lo <= 0.5 <= hi:
        parts.append(f'<line x1="{pad}" x2="{width - pad}" y1="{half:.1f}" y2="{half:.1f}" stroke="var(--muted)" stroke-dasharray="4 4"/>')
    for key, color in series:
        pts = " ".join(f"{x:.1f},{y:.1f}" for x, y in (xy(i, g[key]) for i, g in enumerate(gens) if key in g))
        parts.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="2"/>')
    parts.append(f'<text x="{pad}" y="{height - 6}">generation {gens[0]["generation"]}</text>')
    parts.append(f'<text x="{width - pad - 90}" y="{height - 6}">generation {gens[-1]["generation"]}</text>')
    parts.append("</svg>")
    legend = ('<div class=legend><span><i class=swatch style="background:var(--accent)"></i>search mean</span>'
              '<span><i class=swatch style="background:var(--best)"></i>best candidate</span>'
              '<span><i class=swatch style="background:var(--avg)"></i>average candidate</span>'
              '<span class=meta>dashed: 0.5, even with the opponents</span></div>')
    return "".join(parts) + legend


def render() -> str:
    sources = read_sources()
    games: list[tuple[str, str, float]] = []
    heads: dict[tuple[str, str], list[Any]] = {}
    latest: list[tuple[float, str, dict[str, Any], dict[str, Any]]] = []
    progress = []
    trainings = []
    for source in sources:
        label = source.get("label", "?")
        path = Path(source.get("path", ""))
        if source.get("kind") == "search":
            gens = lines_of(path / "generations.jsonl")
            trainings.append((label, path, gens))
            continue
        results = [r for r in lines_of(path) if r.get("ok")]
        mtime = path.stat().st_mtime if path.exists() else 0
        progress.append((label, len(results), source.get("expected")))
        for index, r in enumerate(results):
            m = r.get("match", {})
            a, b = side_label(m.get("a", {}), label), side_label(m.get("b", {}), label)
            p = points(r, "a")
            games.append((a, b, p))
            h = heads.setdefault((a, b), [0, 0, 0, 0, 0.0, 0, 0.0])
            h[0] += 1
            h[1 if p > 0.5 else 2 if p < 0.5 else 3] += 1
            share = strength(r["a"]) / max(strength(r["a"]) + strength(r["b"]), 1e-6)
            h[4] += share
            h[5] += 1 if r.get("reason") == "commander" else 0
            h[6] += r.get("seconds", 0) / 60
            latest.append((mtime + index * 1e-3, label, r, {"a": a, "b": b, "p": p}))
    now = time.strftime("%H:%M:%S")
    running = playing_now()
    out = [f"<!doctype html><html lang=en><head><meta charset=utf-8><meta http-equiv=refresh content=15>"
           f"<meta name=viewport content=\"width=device-width, initial-scale=1\"><title>Rust AI Live</title>"
           f"<style>{STYLE}</style></head><body><main>",
           "<h1>Rust AI, live</h1>",
           f"<div class=meta>Updated {now} · {len(games)} games finished · {running} playing now · reloads every 15 s</div>"]

    out.append("<h2>Runs</h2><section><table><tr><th>Run</th><th>Kind</th><th>Progress</th></tr>")
    for label, done, expected in progress:
        bar = f"<span class=bar><span style='width:{min(100, 100 * done / expected):.0f}%'></span></span>" if expected else ""
        out.append(f"<tr><td>{esc(label)}</td><td>evaluation</td><td class=num>{done}{' / ' + str(expected) if expected else ''} games {bar}</td></tr>")
    for label, _, gens in trainings:
        last = gens[-1] if gens else None
        what = f"generation {last['generation']} done, {last['games_played']} games" if last else "first generation playing"
        out.append(f"<tr><td>{esc(label)}</td><td>training (CMA-ES)</td><td>{esc(what)}</td></tr>")
    if not progress and not trainings:
        out.append("<tr><td colspan=3 class=meta>no runs yet</td></tr>")
    out.append("</table></section>")

    for label, path, gens in trainings:
        out.append(f"<h2>Training: {esc(label)}</h2><section>")
        if not gens:
            out.append("<div class=meta>its first generation is still playing; results appear once a generation is done</div>")
        else:
            out.append(chart(gens))
            out.append("<table><tr><th>Gen</th><th>Games</th><th>Minutes</th><th>σ</th><th>Mean</th><th>Best</th><th>Average</th><th>Mean against each</th></tr>")
            for g in reversed(gens[-40:]):
                vs = ", ".join(f"{esc(k)} {v:.2f}" for k, v in g.get("mean_vs", {}).items())
                out.append(f"<tr><td class=num>{g['generation']}</td><td class=num>{g['games']}</td><td class=num>{g['minutes']}</td>"
                           f"<td class=num>{g['sigma']:.3f}</td><td class=num><b>{g['mean_fitness']:.3f}</b></td>"
                           f"<td class=num>{g['best_fitness']:.3f}</td><td class=num>{g['average_fitness']:.3f}</td><td>{vs}</td></tr>")
            out.append("</table>")
            out.append(f"<div class=note>Fitness is the mean points a candidate took (a win 1, a loss 0, a game at its time limit 0.1 to 0.9 by who was ahead). "
                       f"The search's mean plays as <code>{esc(str(path / 'best.json'))}</code>.</div>")
        out.append("</section>")

    out.append("<h2>OpenSkill ratings</h2><section><table><tr><th>AI</th><th>OS (μ − σ)</th><th>μ</th><th>σ</th><th>Games</th><th>W–L–D</th><th>Mean points</th></tr>")
    for os_, mu, sigma, name, rec in ratings_table(games):
        out.append(f"<tr><td>{esc(name)}</td><td class=num><b>{os_:.2f}</b></td><td class=num>{mu:.2f}</td><td class=num>{sigma:.2f}</td>"
                   f"<td class=num>{rec[0]}</td><td class=num>{rec[1]}–{rec[2]}–{rec[3]}</td><td class=num>{rec[4] / rec[0]:.3f}</td></tr>")
    if not games:
        out.append("<tr><td colspan=7 class=meta>no games yet</td></tr>")
    out.append("</table><div class=note>Weng-Lin Plackett-Luce as tools/ai_arena/openskill_table.py rates, averaged over 100 orderings. "
               "A commander kill is a win; a game at its time limit is worth 0.1 to 0.9 by the share of worth plus damage dealt.</div></section>")

    out.append("<h2>Head to head (side A's view)</h2><section><table><tr><th>Side A</th><th>Side B</th><th>Games</th><th>W–L–D</th><th>A's score share</th><th>Commander kills</th><th>Mean length</th></tr>")
    for (a, b), h in heads.items():
        share = h[4] / h[0]
        out.append(f"<tr><td>{esc(a)}</td><td>{esc(b)}</td><td class=num>{h[0]}</td><td class=num>{h[1]}–{h[2]}–{h[3]}</td>"
                   f"<td class=num>{share:.0%} <span class=bar><span style='width:{share * 100:.0f}%'></span></span></td>"
                   f"<td class=num>{h[5]}</td><td class=num>{h[6] / h[0]:.1f} min</td></tr>")
    out.append("</table><div class=note>Each scenario is played from both starts.</div></section>")

    out.append("<h2>Latest games</h2><section><table><tr><th>Run</th><th>Map / seed / line</th><th>Side A</th><th>Side B</th><th>Result</th><th>How</th><th>Score A–B</th><th>Mex A–B</th><th>Income A–B</th><th>Army A–B</th></tr>")
    for _, label, r, names in sorted(latest, key=lambda x: x[0], reverse=True)[:30]:
        m = r.get("match", {})
        if r.get("reason") == "commander":
            res = f"{names['a'] if r.get('winner') == 'a' else names['b']} won" if r.get("winner") else "draw"
            how = f"commander killed, {r.get('seconds', 0) / 60:.1f} min"
        else:
            p = names["p"]
            res = f"{names['a']} ahead" if p > 0.55 else f"{names['b']} ahead" if p < 0.45 else "about even"
            how = f"time limit, {r.get('seconds', 0) / 60:.1f} min"
        cls = "win" if names["p"] > 0.5 and names["a"] == label else "loss" if names["p"] < 0.5 and names["a"] == label else ""
        a, b = r["a"], r["b"]
        out.append(f"<tr><td>{esc(label)}</td><td>{esc(m.get('preset'))} / {esc(m.get('seed'))} / {esc(m.get('line'))}{' swapped' if m.get('swap') else ''}</td>"
                   f"<td>{esc(names['a'])}</td><td>{esc(names['b'])}</td><td class={cls}>{esc(res)}</td><td>{esc(how)}</td>"
                   f"<td class=num>{strength(a):.0f} – {strength(b):.0f}</td><td class=num>{a.get('extractors')} – {b.get('extractors')}</td>"
                   f"<td class=num>{a.get('metal_income')} – {b.get('metal_income')}</td>"
                   f"<td class=num>{a.get('worth', {}).get('army', 0):.0f} – {b.get('worth', {}).get('army', 0):.0f}</td></tr>")
    out.append("</table></section></main></body></html>")
    return "\n".join(out)


def write() -> None:
    LIVE.mkdir(parents=True, exist_ok=True)
    temporary = PAGE.with_suffix(".tmp")
    temporary.write_text(render(), encoding="utf-8")
    temporary.replace(PAGE)


def main() -> None:
    if len(sys.argv) > 1 and sys.argv[1] == "add":
        kind, label, path = sys.argv[2], sys.argv[3], sys.argv[4]
        expected = int(sys.argv[5]) if len(sys.argv) > 5 else None
        add_source(kind, label, path, expected)
        write()
        return
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--every", type=float, default=15)
    parser.add_argument("--once", action="store_true")
    options = parser.parse_args()
    while True:
        try:
            write()
        except Exception as error:  # a half-written line or a file in use: try again next time
            print(f"live: {error}", file=sys.stderr, flush=True)
        if options.once:
            return
        time.sleep(options.every)


if __name__ == "__main__":
    main()
