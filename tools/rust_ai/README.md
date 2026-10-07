# The Rust AI

A second computer player, written from scratch in Rust, that plays the real game headless in the AI arena
(`tools/ai_arena`) against server/ai's profiles. It is built on BARb, BAR's own computer player (CircuitAI's
`barbarian` branch, https://github.com/rlcevg/CircuitAI/tree/barbarian, with its settings in Beyond-All-Reason's
`luarules/configs/BARb/stable/config/hard`): its threat and influence maps, its enemy groups, its fight and raid target
choice, its response table and lab tiers, its openers and its economy rules are BARb's, ported from its source. On top
of that it simulates fights unit by unit before it takes them, keeps a map of where it is winning and losing, and gets
desperate when it is falling behind. Every number it decides by can be searched with CMA-ES.

It plays only in the arena: the game on Roblox runs server/ai.

## How it plays the game

`bridge.luau` starts one `rust_ai` process per team it plays and talks to it in lines of JSON: first `hello` (every
def's numbers, the map's open ground for each kind of walker, its heights, the metal spots, the starts), then every
second an `observe` (every team's bank, everything on the map), answered by commands. The bridge carries them out
through what a player's orders go through (`orders.issue`, `production.enqueue`, `placement`): the Rust AI pays for
what it builds, walks where it goes, builds only what its builders can where the game lets it, and sees what server/ai
sees by default (everything). It routes its own units (`path.rs`), round danger, and sends the routes as waypoints.

A side of a duel is played by it with `{"engine": "rust"}`, and given numbers with `"params": {...}`:

```
cargo build --release --manifest-path tools/rust_ai/Cargo.toml
python tools/ai_arena/arena.py '{"mode": "duel", "preset": "highlands", "seed": 3, "line": "bot",
    "a": {"engine": "rust"}, "b": {"profile": "raider"}, "seconds": 1500}'
python tools/ai_arena/evaluate.py --profile '{"engine": "rust"}' --against raider,swarm,sim_barb,barb --scenarios 5
```

A side may also give `"log": "<file>"` (a line of what it thinks each second) and `"exe"` (another build). The result
has `a_rust` / `b_rust`: its report (attacks, raids, defences, retreats, desperation, what it made, the simulator's and
the pathfinder's use, and how long it thought).

## What it does (src/)

- `fields.rs`: BARb's threat map (`map/ThreatMap.cpp`): each enemy thing's threat, its damage kernel
  (sqrt(dps) * damage^0.25 / 128, `unit/CircuitDef.cpp`) times the square root of its health, over its reach with
  BARb's slack, fading to half at the edge and led by a second of its velocity, for the surface and the air; and
  BARb's influence map (`map/InfluenceMap.cpp`). Beside them: its own threat, what each side has worth destroying, and
  the metal lying about.
- `groups.rs`: the enemy in groups by k-means, as BARb's `EnemyManager` has them, with their threat, cost, what of it
  is in each role, and BARb's "vague metric" (threat over cost) that attacks go by.
- `sim.rs`: the battle simulator. Every thing on its own, shot by shot: the game's targeting (worth for the health it
  takes to kill), reloads and overkill, shells in flight that land where their target was, scatter, splash with its
  falloff, death explosions, autoheal, walking into range, crowding, and kiting for the side that kites.
  `rust_ai --predict` holds it up against staged fights played in the real game (below).
- `fronts.rs`: where it is winning and losing: the map in regions, each with both sides' power, what each has there,
  and what each has lost there lately; won, lost or contested by the two ratios. Its standing (what it has, and its
  income, against the enemy's), its trend over the last minute, and its desperation.
- `economy.rs`: BARb's economy and builders: the commander's opening, extractors by richness over walking time where
  the threat map is quiet, energy by a ratio to metal that grows over the game (and when it stalls), labs by income
  and when metal piles up, the advanced lab, an air lab while the enemy's anti-air is thin, construction turrets,
  converters, storage, BARb's porcupine defences by extractors and anti-air at home, extractor upgrades, reclaim,
  resurrection, and help for projects that would outlast BARb's goal_exec and for its labs.
- `factory.rs`: BARb's lab choices: its openers, constructors while buildpower is short (or while its income wants
  more), and fighters by BARb's roulette of response probability (response.json) times lab tier weight
  (factory.json), multiplied by how a budget of each fares against the enemy's actual army in the simulator.
- `military.rs`: BARb's fighter tasks: retreat to be mended, defence of its territory sized by BARb's defence
  modifier, attacks on BARb's choice of enemy group, raids on what the threat map leaves unguarded, anti-air; each
  fight checked in the simulator before it is taken and again as it goes, units that outrange what they fight kept
  out of its reach, and the commander kept safe and firing its manual weapon. Desperation lowers its margins, sends
  more raids, and past a point sends everything at the enemy's commander; far enough ahead, it goes to finish the game.
- `params.rs`: every number above, with its range. `rust_ai --schema` prints them.
- `data/barb.json`: what BARb's config says of this game's units (roles, retreat health, threat and power modifiers,
  lab tier weights), the response table, and the quotas; `barb_import.py` builds it from BAR's files, matching each
  def by the `-- bar:` line over it in `src/shared/unit_defs`.

## Checking the simulator

```
echo '{"mode": "rust_hello", "preset": "prairie", "seed": 1}' | lune run tools/ai_arena/arena.luau - > hello.json
tools/rust_ai/target/release/rust_ai.exe --predict hello.json tools/ai_arena/runs/fights.jsonl
```

reads fights `tools/ai_arena/fight_check.py` played, and says how often the simulator named the real winner, beside
server/ai's predictor (`PREDICT_VERBOSE=1` lists the ones it got wrong, `PREDICT_TRACE=<def>` plays out the fights
with that def second by second).

## Searching its numbers

```
python tools/rust_ai/search.py --run runs/search1 --hours 10
```

CMA-ES over every number in `params.rs`, each candidate scored by the points it takes off server/ai's profiles and a
hall of fame of the search's own champions; `best.json` in the run's folder is the search's mean, which plays as
`{"engine": "rust", "params": <best.json>}`. `runs/` is not kept by git.
