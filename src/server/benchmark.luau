--!strict
-- Automated performance scenarios for /benchmark: each spawns a batch of real entities in a corner
-- of the map, warps the simulation under them for a fixed number of ticks while the profiler
-- measures it, kills everything it made, and moves on to the next. Warping (rather than waiting
-- out a span of real time) means a scenario's step count - and so its results - doesn't depend on
-- how fast the machine running it happens to be. The result is a block of text meant to be pasted
-- back for analysis, not read off the console as it happens.
--
-- Entities are created directly with state.create_entity, not through the normal build/command
-- path, so none of it depends on a player being present. Its two teams, made the first time it runs
-- and kept for every run after, are allied with nobody, so combat scenarios fight for real, and have
-- no economy (economy.set_unlimited): what is measured is what the work costs to simulate, not how
-- quickly an economy runs dry.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local switches = require(ReplicatedStorage.Shared.switches)

local state = require(script.Parent.state)
local orders = require(script.Parent.orders)
local deaths = require(script.Parent.deaths)
local profiler = require(script.Parent.profiler)
local production = require(script.Parent.production)
local transport = require(script.Parent.transport)
local scavengers = require(script.Parent.scavengers)
local warp = require(script.Parent.warp)
local players = require(script.Parent.players)
local economy = require(script.Parent.economy)

type Entity = types.Entity
type EntityId = types.EntityId
type TeamId = types.TeamId
type Order = types.Order

-- The benchmark's two teams, once it has run.
local benchmark_teams: { a: TeamId, b: TeamId }? = nil

-- Tucked into a corner, well clear of where a player's start ever is, so a benchmark run never litters a live game near
-- anyone's base. The bounding box, ARENA_SPAN across from its corner, is swept clean of everything - any team, any kind,
-- wrecks included - between scenarios, since combat leaves wrecks that the set of ids a setup spawned would not
-- otherwise catch.
--
-- Every scenario only ever offsets inward from the corner (`corner.x - n`, `corner.z - n`), never out past it, so
-- `resolve_arena` below can move the corner itself without anything else needing to change.
local ARENA_MARGIN = 60
local ARENA_SPAN = 420

-- How far inward each retry step moves the corner along its own diagonal, and how many tries before giving up on
-- finding dry land at all.
local ARENA_RETRY_STEP = 60
local ARENA_RETRY_LIMIT = 10

-- The arena's corner, set by resolve_arena() at the start of every run, from the map as it is then.
local corner = { x = 0, z = 0 }

local running = false

-- Whether the arena's whole footprint, corner at (x, z), is dry enough to spawn land units on: a coarse sample of the
-- corner, the far inward corner of the footprint, and its centre. A map preset can just as easily put ocean in the
-- corner this used to assume was always safe, and a land unit (whose footing's max_depth is 0, most of them) spawned in
-- water it cannot tolerate drowns within moments of existing - exactly what happened to the "idle" scenario's grunts.
local function arena_is_dry(x: number, z: number): boolean
	for _, sample in
		{
			{ x, z },
			{ x - ARENA_SPAN, z },
			{ x, z - ARENA_SPAN },
			{ x - ARENA_SPAN, z - ARENA_SPAN },
			{ x - ARENA_SPAN / 2, z - ARENA_SPAN / 2 },
		}
	do
		if heightmap.water_depth(sample[1], sample[2]) > 0 then
			return false
		end
	end
	return true
end

-- Moves the arena's corner inward along its own diagonal, up to ARENA_RETRY_LIMIT tries, until its footprint tests dry.
-- Called at the start of every run, since the map may have been replaced since the last. Returns a warning line for the
-- report (rather than logging it directly) if nothing dry was found at all, so the whole benchmark still comes out as
-- the one message run() promises, not an extra print ahead of it.
local function resolve_arena(): string?
	local half_x, half_z = heightmap.half_extents()
	for attempt = 0, ARENA_RETRY_LIMIT do
		local x = half_x - ARENA_MARGIN - attempt * ARENA_RETRY_STEP
		local z = half_z - ARENA_MARGIN - attempt * ARENA_RETRY_STEP
		if arena_is_dry(x, z) then
			corner.x = x
			corner.z = z
			return nil
		end
	end
	corner.x = half_x - ARENA_MARGIN
	corner.z = half_z - ARENA_MARGIN
	return "No dry spot found for the benchmark arena along its usual corner; results may include drowning"
end

-- Kills everything standing in the arena's bounding box, whoever it belongs to.
local function clear_arena()
	for _, entity in state.all() do
		if
			entity.alive
			and entity.position.X >= corner.x - ARENA_SPAN
			and entity.position.X <= corner.x
			and entity.position.Z >= corner.z - ARENA_SPAN
			and entity.position.Z <= corner.z
		then
			deaths.destroy(entity, "removed")
		end
	end
end

-- The benchmark's two teams, made the first time it runs.
local function sides(): { a: TeamId, b: TeamId }
	local made: { a: TeamId, b: TeamId } = benchmark_teams
		or { a = players.create_team "Benchmark A", b = players.create_team "Benchmark B" }
	benchmark_teams = made
	economy.set_unlimited(made.a, true)
	economy.set_unlimited(made.b, true)
	return made
end

-- One order of `kind` to `position`, for units to be given as they are put down.
local function heading(kind: types.OrderKind, position: Vector3): { Order }
	return { { kind = kind, position = position } }
end

-- `count` things of `def_name` in a grid starting at (origin_x, origin_z), `spacing` studs apart, `columns` wide, each
-- made by `make` from its index (from 0) and where it rests; their ids.
local function grid(
	def_name: string,
	origin_x: number,
	origin_z: number,
	count: number,
	spacing: number,
	columns: number,
	make: (index: number, position: Vector3) -> Entity
): { EntityId }
	local def = unit_defs.get(def_name)
	local ids = {}
	for index = 0, count - 1 do
		local x = origin_x + (index % columns) * spacing
		local z = origin_z + (index // columns) * spacing
		table.insert(ids, make(index, Vector3.new(x, surface.height(def, x, z), z)).id)
	end
	return ids
end

-- Finished `def_name`s of `team_id` in a grid (`grid`), each given `given` (orders mutate as they run, so each has its
-- own copy).
local function units(
	def_name: string,
	team_id: TeamId,
	origin_x: number,
	origin_z: number,
	count: number,
	spacing: number,
	columns: number,
	given: { Order }?
): { EntityId }
	return grid(
		def_name,
		origin_x,
		origin_z,
		count,
		spacing,
		columns,
		function(_index: number, position: Vector3): Entity
			local entity = state.create_entity(def_name, team_id, position, 0, "active")
			if given ~= nil then
				orders.issue(entity, given, false, false)
			end
			return entity
		end
	)
end

-- Like `units`, but each one's order of `kind` targets one of `target_ids` in turn (cycling if there are fewer targets
-- than units), for reclaim/resurrect/assist - anything that needs a specific per-unit target rather than one shared
-- order.
local function units_targeting(
	def_name: string,
	team_id: TeamId,
	origin_x: number,
	origin_z: number,
	count: number,
	spacing: number,
	columns: number,
	kind: types.OrderKind,
	target_ids: { EntityId }
): { EntityId }
	return grid(
		def_name,
		origin_x,
		origin_z,
		count,
		spacing,
		columns,
		function(index: number, position: Vector3): Entity
			local entity = state.create_entity(def_name, team_id, position, 0, "active")
			orders.issue(entity, { { kind = kind, target_id = target_ids[(index % #target_ids) + 1] } }, false, false)
			return entity
		end
	)
end

-- Wrecks of `def_name` in a grid, the same wreck a real death leaves.
local function wrecks(
	def_name: string,
	origin_x: number,
	origin_z: number,
	count: number,
	spacing: number,
	columns: number
): { EntityId }
	return grid(
		def_name,
		origin_x,
		origin_z,
		count,
		spacing,
		columns,
		function(_index: number, position: Vector3): Entity
			return state.create_wreck(def_name, position, 0)
		end
	)
end

-- Blueprints of `def_name` in a grid, already standing (not travelled to), at 0 progress.
local function blueprints(
	def_name: string,
	team_id: TeamId,
	origin_x: number,
	origin_z: number,
	count: number,
	spacing: number,
	columns: number
): { EntityId }
	return grid(
		def_name,
		origin_x,
		origin_z,
		count,
		spacing,
		columns,
		function(_index: number, position: Vector3): Entity
			return state.create_entity(def_name, team_id, position, 0, "blueprint")
		end
	)
end

-- What scenarios are made of ----------------------------------------------------------------------------------------

-- `count` of `def_name` for each of `team_a` and `team_b`, `spacing` apart and `columns` wide, round `center_a` and `center_b`,
-- each side fighting its way to the other's.
local function armies_fighting(
	team_a: TeamId,
	team_b: TeamId,
	def_name: string,
	center_a: Vector3,
	center_b: Vector3,
	count: number,
	spacing: number,
	columns: number
)
	units(def_name, team_a, center_a.X, center_a.Z, count, spacing, columns, heading("fight", center_b))
	units(def_name, team_b, center_b.X, center_b.Z, count, spacing, columns, heading("fight", center_a))
end

-- `count` bot labs of `team`, 20 apart and 4 wide from (x, z), each queued 30 grunts deep.
local function labs_producing(team: TeamId, x: number, z: number, count: number)
	for _, id in units("bot_lab", team, x, z, count, 20, 4, nil) do
		local factory = state.get(id)
		if factory ~= nil then
			for _ = 1, 30 do
				production.enqueue(factory, "grunt")
			end
		end
	end
end

-- `count` bot lab blueprints of `team`, 12 apart and `columns` wide from (x, z), each assisted by its own construction
-- bot from the moment it appears, the bots in the same grid just in front.
local function assisted_blueprints(team: TeamId, x: number, z: number, count: number, columns: number)
	local sites = blueprints("bot_lab", team, x, z, count, 12, columns)
	units_targeting("construction_bot", team, x, z + 20, count, 12, columns, "assist", sites)
end

-- `count` transports of `team` from `from`, each carrying two grunts put down `cargo_z` in front of them, and moving to
-- `to`.
local function loaded_transports(team: TeamId, from: Vector3, to: Vector3, count: number, cargo_z: number)
	local transport_ids = units("hercules", team, from.X, from.Z, count, 15, 10, heading("move", to))
	local cargo_ids = units("grunt", team, from.X, from.Z + cargo_z, count * 2, 8, 20, nil)
	for index, transport_id in transport_ids do
		local carrier = state.get(transport_id)
		local first = state.get(cargo_ids[index * 2 - 1])
		local second = state.get(cargo_ids[index * 2])
		if carrier ~= nil and first ~= nil then
			transport.load(carrier, first)
		end
		if carrier ~= nil and second ~= nil then
			transport.load(carrier, second)
		end
	end
end

export type Scenario = {
	name: string,
	description: string,
	-- how many simulation steps the scenario runs for, measured in ticks rather than wall-clock seconds, so a run is the
	-- same length regardless of how fast warp manages to go
	ticks: number,
	-- puts the scenario down for the benchmark's two teams
	setup: (a: TeamId, b: TeamId) -> (),
	-- run after clear_arena(), for anything a scenario made that could have wandered outside the bounding box by the
	-- time it is torn down - a scavenger beacon's own hunters, say
	teardown: (() -> ())?,
}

local SCENARIOS: { Scenario } = {
	{
		name = "idle",
		description = "900 idle grunts, scattered, doing nothing",
		ticks = 100,
		setup = function(a: TeamId, _b: TeamId)
			units("grunt", a, corner.x - 260, corner.z - 260, 900, 8, 30, nil)
		end,
	},
	{
		name = "melee",
		description = "350 v 350 grunts, closing in and fighting to the death",
		ticks = 200,
		setup = function(a: TeamId, b: TeamId)
			local center_a = Vector3.new(corner.x - 320, 0, corner.z - 160)
			local center_b = Vector3.new(corner.x - 160, 0, corner.z - 320)
			armies_fighting(a, b, "grunt", center_a, center_b, 350, 7, 19)
		end,
	},
	{
		name = "ranged",
		description = "220 v 220 aggravators (rockets), closing in and fighting to the death",
		ticks = 200,
		setup = function(a: TeamId, b: TeamId)
			local center_a = Vector3.new(corner.x - 330, 0, corner.z - 170)
			local center_b = Vector3.new(corner.x - 170, 0, corner.z - 330)
			armies_fighting(a, b, "aggravator", center_a, center_b, 220, 9, 15)
		end,
	},
	{
		name = "movement",
		description = "900 ticks, all given the same far move order at once",
		ticks = 160,
		setup = function(a: TeamId, _b: TeamId)
			local target = heightmap.ground_position(corner.x, corner.z)
			units("tick", a, corner.x - 350, corner.z - 350, 900, 6, 30, heading("move", target))
		end,
	},
	{
		name = "production",
		description = "16 bot labs, each queued 30 grunts deep, building continuously",
		ticks = 200,
		setup = function(a: TeamId, _b: TeamId)
			labs_producing(a, corner.x - 200, corner.z - 200, 16)
		end,
	},
	{
		name = "construction",
		description = "180 blueprints, each assisted by its own construction_bot from the moment it appears",
		ticks = 200,
		setup = function(a: TeamId, _b: TeamId)
			assisted_blueprints(a, corner.x - 320, corner.z - 320, 180, 13)
		end,
	},
	{
		name = "reclaim_resurrect",
		description = "300 wrecks; 45 graverobbers reclaiming half of them, 45 resurrecting the other half",
		ticks = 200,
		setup = function(a: TeamId, _b: TeamId)
			local lying = wrecks("grunt", corner.x - 350, corner.z - 350, 300, 6, 18)
			local half = #lying // 2
			local to_reclaim, to_resurrect = {}, {}
			for index, id in lying do
				table.insert(if index <= half then to_reclaim else to_resurrect, id)
			end
			units_targeting("graverobber", a, corner.x - 350, corner.z - 320, 45, 12, 12, "reclaim", to_reclaim)
			units_targeting("graverobber", a, corner.x - 200, corner.z - 320, 45, 12, 12, "resurrect", to_resurrect)
		end,
	},
	{
		name = "transport",
		description = "70 loaded transports shuttling between two points",
		ticks = 160,
		setup = function(a: TeamId, _b: TeamId)
			local from = Vector3.new(corner.x - 350, 0, corner.z - 350)
			local to = Vector3.new(corner.x - 50, 0, corner.z - 50)
			loaded_transports(a, from, to, 70, 200)
		end,
	},
	{
		name = "mixed",
		description = "a late-game slice: two mixed armies fighting, factories producing, builders "
			.. "building and reclaiming, loaded transports, and an active scavenger beacon, all at once",
		ticks = 400,
		teardown = function()
			scavengers.clear()
			switches.set("scavengers", false)
		end,
		setup = function(a: TeamId, b: TeamId)
			local center_a = Vector3.new(corner.x - 300, 0, corner.z - 100)
			local center_b = Vector3.new(corner.x - 100, 0, corner.z - 300)
			armies_fighting(a, b, "grunt", center_a, center_b, 100, 7, 10)
			units("aggravator", a, center_a.X - 100, center_a.Z, 50, 9, 10, heading("fight", center_b))
			units("aggravator", b, center_b.X, center_b.Z - 100, 50, 9, 10, heading("fight", center_a))

			labs_producing(a, corner.x - 400, corner.z - 400, 4)
			assisted_blueprints(a, corner.x - 400, corner.z - 320, 40, 10)
			local lying = wrecks("grunt", corner.x - 400, corner.z - 280, 60, 6, 15)
			units_targeting("graverobber", a, corner.x - 400, corner.z - 260, 20, 12, 10, "reclaim", lying)
			loaded_transports(
				a,
				Vector3.new(corner.x - 400, 0, corner.z - 240),
				Vector3.new(corner.x - 50, 0, corner.z - 50),
				10,
				30
			)

			-- on for exactly this scenario's window; the benchmark keeps it off the rest of the time (see run()) so a
			-- fresh beacon never spawns on its own natural schedule mid-scenario and hunts down units a scenario never
			-- meant to have an enemy at all
			switches.set("scavengers", true)
			scavengers.force_beacon(corner.x - 50, corner.z - 400)
		end,
	},
}

local function format_time_row(row: profiler.Row): string
	return `    {row.label}: {string.format("%.2f", row.ms_per_step)}ms/step, {string.format("%.1f", row.fraction * 100)}%`
end

local function format_count_row(row: profiler.CountRow): string
	return `    {row.label}: {row.count} ({if row.delta >= 0 then "+" else ""}{row.delta})`
end

-- Runs every scenario in turn and calls `log` exactly once, with the whole report as a single
-- newline-joined string, once it is all done - pow prints one call as one message, which is what
-- makes the result copyable in one go instead of scattered across a run of separate prints. Blocks
-- the calling coroutine for the whole run (a couple of minutes) rather than kicking it off in the
-- background, so a caller waiting on this - like pow's server_run, which the client invokes and
-- blocks on - only gets control back once the report is actually ready. Returns false without doing
-- anything if a run is already in progress.
local function run(log: (string) -> ())
	if running then
		log "A benchmark is already running"
		return false
	end
	running = true
	local started_at = os.clock()
	-- the scavengers are kept off and the simulation warped for the run, and both are put back as they were once it is
	-- over, however it ended
	local was_enabled = switches.is_on "scavengers"
	local was_remaining = warp.ticks_remaining()

	local ok, err = pcall(function()
		local lines: { string } = { `Benchmark: {#SCENARIOS} scenarios` }
		local arena_warning = resolve_arena()
		if arena_warning ~= nil then
			table.insert(lines, arena_warning)
		end

		-- in case a previous run was interrupted partway through and left its own debris behind, a
		-- surviving scavenger beacon included
		clear_arena()
		scavengers.clear()

		-- off for every scenario but "mixed" (which turns it back on for exactly its own window),
		-- so a beacon can never spawn on its own natural schedule mid-scenario and go hunting units
		-- a scenario never meant to have an enemy at all
		switches.set("scavengers", false)

		-- warped for the whole run so every scenario is measured over a fixed number of ticks
		-- rather than however many ticks real time happens to buy it
		warp.start(nil)

		task.wait(tick_rate.TICK_DELTA * 3)

		local teams_of_run = sides()
		for _, scenario in SCENARIOS do
			scenario.setup(teams_of_run.a, teams_of_run.b)
			-- let the spawn itself settle for a tick before the clock starts
			task.wait(tick_rate.TICK_DELTA)
			profiler.reset()
			repeat
				task.wait()
			until profiler.step_count() >= scenario.ticks

			local steps = profiler.step_count()
			local elapsed = profiler.elapsed_since_reset()
			local entities = profiler.entity_report()

			table.insert(lines, "")
			table.insert(lines, `== {scenario.name}: {scenario.description} ==`)
			table.insert(
				lines,
				`  {steps} steps over {string.format("%.2f", elapsed)}s ({string.format(
					"%.2f",
					steps * tick_rate.TICK_DELTA
				)}s sim time)`
			)
			table.insert(lines, `  entities at end: {entities.total}`)
			for _, row in entities.by_kind do
				table.insert(lines, format_count_row(row))
			end
			for _, row in profiler.report() do
				table.insert(lines, format_time_row(row))
			end

			clear_arena()
			if scenario.teardown ~= nil then
				scenario.teardown()
			end
			-- give the normal step loop a couple of ticks to actually reap what was just killed
			-- before the next scenario's counts start from a clean slate
			task.wait(tick_rate.TICK_DELTA * 3)
		end

		table.insert(lines, "")
		-- wall-clock, not sim time: with every scenario now warped to a fixed tick count (see
		-- SCENARIOS above), this is what actually moves when a change makes a step cheaper, so it
		-- doubles as the one number worth diffing between two versions' runs
		table.insert(lines, `Total time: {string.format("%.2f", os.clock() - started_at)}s`)
		table.insert(lines, "Benchmark complete")
		log(table.concat(lines, "\n"))
	end)

	switches.set("scavengers", was_enabled)
	warp.start(was_remaining)
	running = false
	if not ok then
		error(err, 0)
	end

	return true
end

local function is_running(): boolean
	return running
end

return table.freeze({
	run = run,
	is_running = is_running,
})
