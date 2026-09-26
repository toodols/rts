# AI arena

Full AI-vs-AI matches of the real game, headless, outside Roblox: one match per `lune` process, as many processes at
once as the machine has cores. It exists to tune the AI (server/ai and its profiles in
shared/ai_profiles.luau) by playing it against itself a great many times.

## How it runs the game

`lune` is a standalone Luau runtime. The arena loads the game's own modules from `src/`, unchanged, into the stand-in
of the Roblox engine in `tools/lib`, which the headless tests (`tools/headless_tests`) and `tools/game_data.luau` run the
game on too: see `tools/lib/README.md`.

## Running matches

From the repository's root:

```
python tools/ai_arena/arena.py '{"mode": "duel", "preset": "highlands", "seed": 3, "line": "bot",
    "a": {"profile": "default"}, "b": {"profile": "raider"}, "seconds": 900}'
```

or straight through lune, with the match on stdin: `echo '{...}' | lune run tools/ai_arena/arena.luau -`.

A duel's fields: `preset` and `seed` (the map), `random_seed` (the game's chance; the map's seed if not given),
`line` (`bot` or `vehicle`: both sides build from that line, but a profile with a line of its own keeps it), `a` and `b`
(`{"profile": name, "overrides": {...}}`, a named profile with some of its numbers changed; `"none"` leaves one out,
switching it off or lifting its limit), `swap` (`b` takes the first start and team 1), `seconds` (the time limit),
`every` (look at both sides every so many seconds and keep a timeline, with each AI's report), `profile` (where the
step's time went), `scenery` (keep the map's rocks and trees) and `root` (play the game's source from another checkout).

It ends when a side is out, its commander dead as the game's own match end has it (the other side wins; both at once
is a draw), or at the time limit. The result has, for each side: whether its commander stands, its units and buildings, what they are worth (army, builders, economy,
defence, labs, as metal + energy / 60), its incomes, what it has made, what it destroyed and lost, its waves and raids.

`{"mode": "ai_match", ...}` runs src/server/tests/ai.luau's `ai_match` test itself, to hold the arena up
against Studio: `python tools/ai_arena/validate.py '{"seconds": 180, "every": 60, "random_seed": 42}'` prints it in
the shape a Studio run is read in.

`arena.play_many(matches, workers)` in Python plays a list of matches across worker processes.

## Checking the fight predictor

`server/ai/combat_sim.luau` predicts a fight without playing it (the AI asks it before it commits, with the profile's
`sim_attack`, `sim_retreat` and `sim_defend`). `{"mode": "fight", ...}` stages one to hold it up against the game: `a`
and `b` (lists of `{"def": name, "count": n}`) are put down `distance` studs apart across the middle of the map, b's
`b_defences` (and a's `a_defences`) standing within `spread` of their side's middle, and everything that moves is sent
to fight its way to the other side, both with all the energy they want. The predictor's answer is taken before the
first tick, and the fight is played for `seconds` (90) or until one side has nothing armed left. The result has both,
and where everything stood (`start`); `{"mode": "predict", "fights": [start, ...]}` asks the predictor about those
again without playing them.

```
python tools/ai_arena/fight_check.py --count 600 --workers 4 --out tools/ai_arena/runs/fights.jsonl
python tools/ai_arena/fight_check.py --out tools/ai_arena/runs/fights.jsonl --repredict --dump
```

plays that many fights of six families (first tier, second tier, the two mixed, attackers against defences, aircraft
against ground with anti-air, aircraft against aircraft), each side bought from a budget, the second's 0.5 to 2 times
the first's, and reports how often the predictor named the winner, next to the rule the AI used before it (the side
worth more wins), and how far off its remaining worth was. `--repredict` asks the predictor as it is now about fights
already played, which takes seconds, for trying a change to it; `--random-seed` plays the same fights again with the
game's chance rolled another way, to see how far the game agrees with itself.

## Checking how the AI behaves

`python tools/ai_arena/behaviour.py --a sim_barb --b raider --games 24 --out runs/b.jsonl` plays duels with `"watch":
true`, which looks at both sides every second, and sums up per game what the AI did rather than who won: builder-seconds
spent going to or standing at a metal spot an enemy's extractor already holds, and at a site something blocks; raids
sent, the targets each saw destroyed and how they ended; hunts and strikes and their kills; how many places it was
attacking at once (`fronts_mean`); the seconds the enemy's armed units spent in its territory in the first ten minutes
and how many died there; its extractors lost in the first ten minutes; the enemy's extractors it killed a minute; how
far apart its army stands out on the map (`spacing`, the mean distance to the nearest other unit of a group). A side
is a profile's name or `{"profile": ..., "overrides": {...}}`; `--summarise` reads result files again.

`python tools/ai_arena/formation_check.py --spacings 0,6,10` plays staged fights of first-tier bots against
Pounders and Janus, splash weapons, with the bots sent to one point and again spread out in the AI's formation
(`spread`) at each spacing; `--control` plays the same against enemies without splash.

## Ratings

`python tools/ai_arena/openskill_table.py runs/a.jsonl runs/b.jsonl --entrants runs/rr_entrants.json` rates every
profile in the given result files (evaluate.py's `--out`) with OpenSkill (Weng-Lin Plackett-Luce, mu 25, sigma 25/3),
and lists them by the displayed rating, mu - sigma.

## Searching for a better profile

```
python tools/ai_arena/search.py --run runs/search1 --hours 10
```

CMA-ES (`cmaes.py`) over the profile's numbers (`profiles.py`, which reads each one's range and the default from
shared/ai_profiles.luau through `{"mode": "profiles"}`, and says only how each is searched), each
candidate scored by the points it takes off a pool of opponents: the named profiles and a hall of fame of the search's
own champions. A win is 1 and a loss 0; a game that reaches the time limit is scored 0.1 to 0.9 by how far ahead each
side is (what it has plus what it destroyed). Every candidate of a generation plays the same scenarios (map, seeds,
line, opponent) from both starts. The run's folder (under `runs/`, which git ignores) gets every match, a summary of
each generation, and a checkpoint the run resumes from.

`evaluate.py` plays one profile against others over many games and reports win rates with their margins of error.
