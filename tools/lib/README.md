# The Roblox engine, stood in for

`lune` is a standalone Luau runtime. The AI arena (`tools/ai_arena`), the headless tests (`tools/headless_tests`) and
`tools/game_data.luau` load the game's own modules from `src/`, unchanged, into this stand-in of the Roblox engine,
which has just what the server's simulation touches:

- `loader.luau` lays `src/` out the way `rts-game.project.json` does (so `require(script.Parent.state)` and
  `require(ReplicatedStorage.Shared.tick_rate)` resolve), and compiles each module as it is, with two changes that keep
  every line where it was: the Roblox globals (`game`, `script`, `Vector3`, `task`...) come in as locals on the first
  line, and `.Magnitude`, `.Unit`, `:Dot(...)` and the few other things a Roblox Vector3 answers that Luau's own
  vector does not are rewritten into calls that do the same (`vector_rewrite.luau`, which
  `tests/vector_rewrite_test.luau` holds to every idiom and every module in `src/`).
- `engine.luau`: instances (properties, attributes, children), services, signals, remote events that go nowhere,
  and `task.*` on a clock of its own, which whoever steps the game moves on.
- `datatypes.luau`: Vector3 is Luau's native vector (three 32-bit floats, as in Roblox); Vector2 and CFrame are
  tables; Random is Roblox's PCG32 bit for bit (`tests/datatypes_test.luau` holds it against numbers Studio printed).
- `session.luau` sets a game up the way `init.server.luau` sets up a session a Studio test runs in: the map
  built, scavengers off, the rocks and trees cleared (unless asked for), and the game playing from the start.

Only the modules that draw the game for players are stood in for: `terrain.luau` and `instances.luau`.

What a headless game leans on in `src/`:

- `server/bootstrap.luau` starts a session the way the live server and a Studio test start one, and
  `server/simulation.luau` is the one step all three run, so what one of them finds holds for the others.
- `server/rng.luau` rolls everything the game leaves to chance from named streams seeded from one seed. A headless session
  always seeds it; a Studio test does when started with `random_seed`, so the same seed plays the same game in both.
- A duel ends as a game between players does: `server/elimination.luau` says when a side is out.
- The stand-ins (`session.luau`) are built from what the stood-in modules export (`loader.stand_in`), so they keep
  up with them.
