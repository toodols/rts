-- Automated performance scenarios for /benchmark: each spawns a batch of real entities in a corner
-- of the map, lets the simulation run under them for a fixed span while the profiler measures it,
-- kills everything it made, and moves on to the next. The result is a block of text meant to be
-- pasted back for analysis, not read off the console as it happens.
--
-- Entities are created directly with state.create_entity, not through the normal build/command
-- path, so none of this costs metal or energy and none of it depends on a player being present.
-- Teams 90001/90002 are reserved for it and are never allied with anyone, so combat scenarios fight
-- for real.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local profiler = require(script.Parent.profiler)
local production = require(script.Parent.production)
local transport = require(script.Parent.transport)
local scavengers = require(script.Parent.scavengers)

type EntityId = types.EntityId
type TeamId = types.TeamId
type Order = types.Order

local TEAM_A: TeamId = 90001
local TEAM_B: TeamId = 90002

-- Tucked into a corner, well clear of where a player's start ever is, so a benchmark run never
-- litters a live game near anyone's base. The bounding box is swept clean of everything - any team,
-- any kind, wrecks included - between scenarios, since combat leaves wrecks that the set of ids a
-- setup spawned would not otherwise catch.
local ARENA_MARGIN = 60
local ARENA_X = config.MAP_CELLS_X * config.CELL_STUDS / 2 - ARENA_MARGIN
local ARENA_Z = config.MAP_CELLS_Z * config.CELL_STUDS / 2 - ARENA_MARGIN
local ARENA_SPAN = 420
local ARENA_MIN_X = ARENA_X - ARENA_SPAN
local ARENA_MIN_Z = ARENA_Z - ARENA_SPAN

local running = false

-- Kills everything standing in the arena's bounding box, whoever it belongs to.
local function clear_arena()
	for _, entity in state.all() do
		if
			entity.alive
			and entity.position.X >= ARENA_MIN_X
			and entity.position.X <= ARENA_X
			and entity.position.Z >= ARENA_MIN_Z
			and entity.position.Z <= ARENA_Z
		then
			state.mark_dead(entity)
		end
	end
end

-- Generous enough that production, construction and resurrection never stall on affordability
-- partway through a scenario - a late-game team's stockpile, not a fresh one's - since what is being
-- measured is what that work costs to simulate, not how quickly a starting economy runs dry.
local BENCHMARK_RESOURCES = 1e7

local function ensure_team(team_id: TeamId)
	if state.get_team(team_id) == nil then
		local team = state.create_team(team_id)
		team.name = `Benchmark {team_id}`
		team.metal = BENCHMARK_RESOURCES
		team.energy = BENCHMARK_RESOURCES
		team.metal_capacity = BENCHMARK_RESOURCES
		team.energy_capacity = BENCHMARK_RESOURCES
	end
end

-- Places `count` of `def_name` in a grid starting at (origin_x, origin_z), `spacing` studs apart,
-- `columns` wide, each with `orders` (a fresh copy per unit, since orders mutate as they run).
local function grid_spawn(
	def_name: string,
	team_id: TeamId,
	origin_x: number,
	origin_z: number,
	count: number,
	spacing: number,
	columns: number,
	facing: number,
	orders: { Order }?
): { EntityId }
	local def = unit_defs.get(def_name)
	local ids = {}
	for i = 0, count - 1 do
		local row = i // columns
		local col = i % columns
		local x = origin_x + col * spacing
		local z = origin_z + row * spacing
		local y = unit_defs.surface_height(def, x, z)
		local entity = state.create_entity(def_name, team_id, Vector3.new(x, y, z), facing, "active")
		if orders ~= nil then
			entity.orders = table.clone(orders)
		end
		table.insert(ids, entity.id)
	end
	state.flush()
	return ids
end

-- Like grid_spawn, but each unit's order targets one of `target_ids` in turn (cycling if there are
-- fewer targets than units), for reclaim/resurrect/assist - anything that needs a specific per-unit
-- target rather than one shared order.
local function grid_spawn_targeting(
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
	local def = unit_defs.get(def_name)
	local ids = {}
	for i = 0, count - 1 do
		local row = i // columns
		local col = i % columns
		local x = origin_x + col * spacing
		local z = origin_z + row * spacing
		local y = unit_defs.surface_height(def, x, z)
		local entity = state.create_entity(def_name, team_id, Vector3.new(x, y, z), 0, "active")
		local target_id = target_ids[(i % #target_ids) + 1]
		entity.orders = { { kind = kind, target_id = target_id } }
		table.insert(ids, entity.id)
	end
	state.flush()
	return ids
end

-- Wrecks of `def_name` in a grid: a real source entity is made active, wrecked on the spot, and
-- thrown away - state.create_wreck only ever reads a source's def, position and facing, so this is
-- the same wreck a real death leaves, without needing one.
local function spawn_wreck_grid(
	def_name: string,
	origin_x: number,
	origin_z: number,
	count: number,
	spacing: number,
	columns: number
): { EntityId }
	local def = unit_defs.get(def_name)
	local ids = {}
	for i = 0, count - 1 do
		local row = i // columns
		local col = i % columns
		local x = origin_x + col * spacing
		local z = origin_z + row * spacing
		local y = unit_defs.surface_height(def, x, z)
		local source = state.create_entity(def_name, 0, Vector3.new(x, y, z), 0, "active")
		local wreck = state.create_wreck(source)
		state.mark_dead(source)
		table.insert(ids, wreck.id)
	end
	state.flush()
	return ids
end

-- Blueprints of `def_name` in a grid, already standing (not travelled to), at 0 progress.
local function spawn_blueprint_grid(
	def_name: string,
	team_id: TeamId,
	origin_x: number,
	origin_z: number,
	count: number,
	spacing: number,
	columns: number
): { EntityId }
	local def = unit_defs.get(def_name)
	local ids = {}
	for i = 0, count - 1 do
		local row = i // columns
		local col = i % columns
		local x = origin_x + col * spacing
		local z = origin_z + row * spacing
		local y = unit_defs.surface_height(def, x, z)
		local entity = state.create_entity(def_name, team_id, Vector3.new(x, y, z), 0, "blueprint")
		table.insert(ids, entity.id)
	end
	state.flush()
	return ids
end

export type Scenario = {
	name: string,
	description: string,
	duration: number,
	setup: () -> (),
}

local SCENARIOS: { Scenario } = {
	{
		name = "idle",
		description = "400 idle grunts, scattered, doing nothing",
		duration = 5,
		setup = function()
			ensure_team(TEAM_A)
			grid_spawn("grunt", TEAM_A, ARENA_X - 160, ARENA_Z - 160, 400, 8, 20, 0, nil)
		end,
	},
	{
		name = "melee",
		description = "150 v 150 grunts, closing in and fighting to the death",
		duration = 10,
		setup = function()
			ensure_team(TEAM_A)
			ensure_team(TEAM_B)
			local center_a = Vector3.new(ARENA_X - 300, 0, ARENA_Z - 150)
			local center_b = Vector3.new(ARENA_X - 150, 0, ARENA_Z - 300)
			grid_spawn(
				"grunt",
				TEAM_A,
				center_a.X,
				center_a.Z,
				150,
				7,
				13,
				0,
				{ { kind = "fight", position = center_b } }
			)
			grid_spawn(
				"grunt",
				TEAM_B,
				center_b.X,
				center_b.Z,
				150,
				7,
				13,
				0,
				{ { kind = "fight", position = center_a } }
			)
		end,
	},
	{
		name = "ranged",
		description = "100 v 100 aggravators (rockets), closing in and fighting to the death",
		duration = 10,
		setup = function()
			ensure_team(TEAM_A)
			ensure_team(TEAM_B)
			local center_a = Vector3.new(ARENA_X - 350, 0, ARENA_Z - 175)
			local center_b = Vector3.new(ARENA_X - 175, 0, ARENA_Z - 350)
			grid_spawn(
				"aggravator",
				TEAM_A,
				center_a.X,
				center_a.Z,
				100,
				9,
				10,
				0,
				{ { kind = "fight", position = center_b } }
			)
			grid_spawn(
				"aggravator",
				TEAM_B,
				center_b.X,
				center_b.Z,
				100,
				9,
				10,
				0,
				{ { kind = "fight", position = center_a } }
			)
		end,
	},
	{
		name = "movement",
		description = "400 ticks, all given the same far move order at once",
		duration = 8,
		setup = function()
			ensure_team(TEAM_A)
			local from_x, from_z = ARENA_X - 350, ARENA_Z - 350
			local target = heightmap.ground_position(ARENA_X, ARENA_Z)
			grid_spawn("tick", TEAM_A, from_x, from_z, 400, 6, 20, 0, { { kind = "move", position = target } })
		end,
	},
	{
		name = "production",
		description = "8 bot labs, each queued 30 grunts deep, building continuously",
		duration = 10,
		setup = function()
			ensure_team(TEAM_A)
			local ids = grid_spawn("bot_lab", TEAM_A, ARENA_X - 200, ARENA_Z - 200, 8, 20, 4, 0, nil)
			for _, id in ids do
				local factory = state.get(id)
				if factory ~= nil then
					for _ = 1, 30 do
						production.enqueue(factory, "grunt")
					end
				end
			end
		end,
	},
	{
		name = "construction",
		description = "80 blueprints, each assisted by its own constructor from the moment it appears",
		duration = 10,
		setup = function()
			ensure_team(TEAM_A)
			local blueprints = spawn_blueprint_grid("bot_lab", TEAM_A, ARENA_X - 320, ARENA_Z - 320, 80, 12, 10)
			grid_spawn_targeting("constructor", TEAM_A, ARENA_X - 320, ARENA_Z - 300, 80, 12, 10, "assist", blueprints)
		end,
	},
	{
		name = "reclaim_resurrect",
		description = "150 wrecks; 25 graverobbers reclaiming half of them, 25 resurrecting the other half",
		duration = 10,
		setup = function()
			ensure_team(TEAM_A)
			local wrecks = spawn_wreck_grid("grunt", ARENA_X - 350, ARENA_Z - 350, 150, 6, 15)
			local half = #wrecks // 2
			local to_reclaim, to_resurrect = {}, {}
			for i, id in wrecks do
				if i <= half then
					table.insert(to_reclaim, id)
				else
					table.insert(to_resurrect, id)
				end
			end
			grid_spawn_targeting("graverobber", TEAM_A, ARENA_X - 350, ARENA_Z - 320, 25, 12, 10, "reclaim", to_reclaim)
			grid_spawn_targeting(
				"graverobber",
				TEAM_A,
				ARENA_X - 200,
				ARENA_Z - 320,
				25,
				12,
				10,
				"resurrect",
				to_resurrect
			)
		end,
	},
	{
		name = "transport",
		description = "30 loaded transports shuttling between two points",
		duration = 8,
		setup = function()
			ensure_team(TEAM_A)
			local from = Vector3.new(ARENA_X - 350, 0, ARENA_Z - 350)
			local to = Vector3.new(ARENA_X - 50, 0, ARENA_Z - 50)
			local transport_ids =
				grid_spawn("hercules", TEAM_A, from.X, from.Z, 30, 15, 10, 0, { { kind = "move", position = to } })
			local cargo_ids = grid_spawn("grunt", TEAM_A, from.X, from.Z + 200, 60, 8, 20, 0, nil)
			for i, transport_id in transport_ids do
				local carrier = state.get(transport_id)
				local first = state.get(cargo_ids[i * 2 - 1])
				local second = state.get(cargo_ids[i * 2])
				if carrier ~= nil and first ~= nil then
					transport.load(carrier, first)
				end
				if carrier ~= nil and second ~= nil then
					transport.load(carrier, second)
				end
			end
		end,
	},
	{
		name = "mixed",
		description = "a late-game slice: two mixed armies fighting, factories producing, builders "
			.. "building and reclaiming, loaded transports, and an active scavenger beacon, all at once",
		duration = 20,
		setup = function()
			ensure_team(TEAM_A)
			ensure_team(TEAM_B)

			local center_a = Vector3.new(ARENA_X - 300, 0, ARENA_Z - 100)
			local center_b = Vector3.new(ARENA_X - 100, 0, ARENA_Z - 300)
			grid_spawn(
				"grunt",
				TEAM_A,
				center_a.X,
				center_a.Z,
				100,
				7,
				10,
				0,
				{ { kind = "fight", position = center_b } }
			)
			grid_spawn(
				"grunt",
				TEAM_B,
				center_b.X,
				center_b.Z,
				100,
				7,
				10,
				0,
				{ { kind = "fight", position = center_a } }
			)
			grid_spawn(
				"aggravator",
				TEAM_A,
				center_a.X - 100,
				center_a.Z,
				50,
				9,
				10,
				0,
				{ { kind = "fight", position = center_b } }
			)
			grid_spawn(
				"aggravator",
				TEAM_B,
				center_b.X,
				center_b.Z - 100,
				50,
				9,
				10,
				0,
				{ { kind = "fight", position = center_a } }
			)

			local factories = grid_spawn("bot_lab", TEAM_A, ARENA_X - 400, ARENA_Z - 400, 4, 20, 4, 0, nil)
			for _, id in factories do
				local factory = state.get(id)
				if factory ~= nil then
					for _ = 1, 30 do
						production.enqueue(factory, "grunt")
					end
				end
			end

			local blueprints = spawn_blueprint_grid("bot_lab", TEAM_A, ARENA_X - 400, ARENA_Z - 320, 40, 12, 10)
			grid_spawn_targeting("constructor", TEAM_A, ARENA_X - 400, ARENA_Z - 300, 40, 12, 10, "assist", blueprints)

			local wrecks = spawn_wreck_grid("grunt", ARENA_X - 400, ARENA_Z - 280, 60, 6, 15)
			grid_spawn_targeting("graverobber", TEAM_A, ARENA_X - 400, ARENA_Z - 260, 20, 12, 10, "reclaim", wrecks)

			local from = Vector3.new(ARENA_X - 400, 0, ARENA_Z - 240)
			local to = Vector3.new(ARENA_X - 50, 0, ARENA_Z - 50)
			local transport_ids =
				grid_spawn("hercules", TEAM_A, from.X, from.Z, 10, 15, 10, 0, { { kind = "move", position = to } })
			local cargo_ids = grid_spawn("grunt", TEAM_A, from.X, from.Z + 30, 20, 8, 20, 0, nil)
			for i, transport_id in transport_ids do
				local carrier = state.get(transport_id)
				local first = state.get(cargo_ids[i * 2 - 1])
				local second = state.get(cargo_ids[i * 2])
				if carrier ~= nil and first ~= nil then
					transport.load(carrier, first)
				end
				if carrier ~= nil and second ~= nil then
					transport.load(carrier, second)
				end
			end

			scavengers.force_beacon(ARENA_X - 50, ARENA_Z - 400)
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
-- makes the result copyable in one go instead of scattered across a run of separate prints. Returns
-- false without doing anything if a run is already in progress.
local function run(log: (string) -> ())
	if running then
		log "A benchmark is already running"
		return false
	end
	running = true

	task.spawn(function()
		local lines: { string } = { `Benchmark: {#SCENARIOS} scenarios` }
		-- in case a previous run was interrupted partway through and left its own debris behind
		clear_arena()
		task.wait(config.TICK_DELTA * 3)

		for _, scenario in SCENARIOS do
			scenario.setup()
			-- let the spawn itself settle for a tick before the clock starts
			task.wait(config.TICK_DELTA)
			profiler.reset()
			task.wait(scenario.duration)

			local steps = profiler.step_count()
			local elapsed = profiler.elapsed_since_reset()
			profiler.sample_entities()
			local entities = profiler.entity_report()

			table.insert(lines, "")
			table.insert(lines, `== {scenario.name}: {scenario.description} ==`)
			table.insert(
				lines,
				`  {steps} steps over {string.format("%.2f", elapsed)}s ({string.format(
					"%.2f",
					steps * config.TICK_DELTA
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
			-- give the normal step loop a couple of ticks to actually reap what was just killed
			-- before the next scenario's counts start from a clean slate
			task.wait(config.TICK_DELTA * 3)
		end

		table.insert(lines, "")
		table.insert(lines, "Benchmark complete")
		log(table.concat(lines, "\n"))
		running = false
	end)

	return true
end

local function is_running(): boolean
	return running
end

return table.freeze({
	run = run,
	is_running = is_running,
})
