-- A game session, headless: the game's modules loaded (loader.luau), and the session started by the server's own
-- bootstrap (src/server/bootstrap.luau) as a session nobody plays in, the way a Studio test's is (session_config's
-- `unplayed`): no players, no scavengers, the game playing from the start, the caller stepping the simulation itself.
-- Only the modules that draw the game for players (terrain and the entities' models) are stood in for.

local loader = require "./loader"
local engine = require "./engine"
local datatypes = require "./datatypes"

export type Options = {
	-- the repository's root, where rts-game.project.json is
	root: string,
	-- the map; if not given, the handed match's (`match`), or else the server's usual one (session_config)
	preset: string?,
	seed: number?,
	-- a match handed in the way a lobby hands one over (shared/game_modes.luau), as a Studio test may hand one in; the
	-- scavengers are then as it has them
	match: any?,
	-- keep the rocks and trees the map starts with, which a Studio test takes away unless asked not to
	scenery: boolean?,
	-- what everything the game leaves to chance is rolled from (server/rng.luau); the map's seed if not given,
	-- so that a headless game always plays the same
	random_seed: number?,
	-- what any other Random.new() with no seed counts from, which in Roblox is entropy
	entropy: number?,
	-- the session as a Studio test asks for it (src/server/tests/init.luau's session_for), in place of all the above
	unplayed: { [string]: any }?,
}

-- the parts of the project a headless session leaves out: a player's client, the packages only the UI and the
-- command bar use
local SKIPPED = {
	["ReplicatedStorage.Client"] = true,
	["ReplicatedStorage.Packages"] = true,
	["ServerScriptService.Server.pow"] = true,
	["StarterPlayer"] = true,
}

-- what any Random.new() with no seed counts from when no `entropy` or `seed` is given, before the game is loaded
local DEFAULT_ENTROPY_SEED = 1337

local TICK_DELTA: number

local laid_out = false

-- Lays the game out, once, so that its modules can be required before a session starts (`start` does it too).
local function load(root: string)
	if laid_out then
		return
	end
	laid_out = true
	loader.build(root, "rts-game.project.json", SKIPPED)
	-- what only draws the game: everything they export does nothing, but that a team's colour is white
	loader.stand_in(root, "src/server/terrain.luau", {})
	loader.stand_in(root, "src/server/instances.luau", {
		team_color = function()
			return datatypes.Color3.new(1, 1, 1)
		end,
	})
end

-- The module at `path` under `root`, its names joined by dots ("ai.combat_sim").
local function module_at(root: any, path: string): any
	local instance = root
	for _, name in string.split(path, ".") do
		instance = instance:FindFirstChild(name)
		assert(instance ~= nil, `there is no module {path}`)
	end
	return loader.require(instance)
end

-- A module of the server's, or a shared one, by its path, once the game is laid out (`load`).
local function server_module(path: string): any
	return module_at(engine.game:GetService("ServerScriptService").Server, path)
end
local function shared_module(path: string): any
	return module_at(engine.game:GetService("ReplicatedStorage").Shared, path)
end

-- Starts a session: loads the game, builds the map, and returns the server's modules by name and a function that
-- runs the simulation on for a number of ticks.
local function start(options: Options)
	datatypes.seed_unseeded(options.entropy or (options.seed or DEFAULT_ENTROPY_SEED) * 7 + 1)
	load(options.root)

	local tick_rate = shared_module "tick_rate"
	TICK_DELTA = tick_rate.TICK_DELTA
	local simulation = server_module "simulation"
	server_module("bootstrap").start(server_module("session_config").unplayed(options.unplayed or {
		match = options.match,
		preset = options.preset,
		seed = options.seed,
		scenery = options.scenery,
		random_seed = options.random_seed,
		seeded = true,
	}))

	local sim_time = 0
	local function advance(ticks: number)
		for _ = 1, ticks do
			simulation.step(TICK_DELTA)
			sim_time += TICK_DELTA
		end
		engine.run_tasks(sim_time)
	end

	return {
		server = server_module,
		shared = shared_module,
		advance = advance,
		tick_delta = TICK_DELTA,
		time = function(): number
			return sim_time
		end,
	}
end

return {
	load = load,
	server = server_module,
	shared = shared_module,
	start = start,
}
