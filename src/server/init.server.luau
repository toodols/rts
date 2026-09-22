-- Server entry point: builds the map, hands each player a starting force, and runs the fixed-step
-- simulation.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local passability = require(ReplicatedStorage.Shared.passability)

local state = require(script.state)
local terrain = require(script.terrain)
local lighting = require(script.lighting)
local economy = require(script.economy)
local flows = require(script.flows)
local wind = require(script.wind)
local construction = require(script.construction)
local reclaim = require(script.reclaim)
local resurrection = require(script.resurrection)
local production = require(script.production)
local drones = require(script.drones)
local drowning = require(script.drowning)
local autoheal = require(script.autoheal)
local docking = require(script.docking)
local movement = require(script.movement)
local combat = require(script.combat)
local shields = require(script.shields)
local transport = require(script.transport)
local projectiles = require(script.projectiles)
local deformation = require(script.deformation)
local orders = require(script.orders)
local instances = require(script.instances)
local commands = require(script.commands)
local players = require(script.players)
local replication = require(script.replication)
local scavengers = require(script.scavengers)
local spawning = require(script.spawning)
local pause = require(script.pause)
local warp = require(script.warp)
local profiler = require(script.profiler)
local benchmark = require(script.benchmark)

type TeamId = types.TeamId

local team_updated: RemoteEvent = ReplicatedStorage.Shared.TeamUpdated

local MAP_SEED = 1337
-- What the ground is like: "highlands" or "islands". See shared/map_presets.luau.
local MAP_PRESET = "koth"
local RESOURCE_BROADCAST_INTERVAL = 0.2

-- While warping, how much real time each Heartbeat may spend running steps back to back before it
-- has to yield and let the engine schedule the next one - not a step count, since how many steps fit
-- in that time depends entirely on what is actually happening in the game right now.
local WARP_TIME_BUDGET = 0.15
-- An absolute cap regardless of the time budget, so a pathologically slow step() cannot still hold a
-- single Heartbeat for a very long time.
local WARP_MAX_STEPS = 500

local accumulator = 0
local broadcast_timer = 0

local function on_player_added(player: Player)
	-- before anything is built, so the world is on its way to the client as it appears
	replication.attach(player)

	local team_id = players.assign(player)
	spawning.give_starting_force(team_id)

	local team = state.get_team(team_id)
	if team ~= nil then
		team_updated:FireClient(player, {
			metal = team.metal,
			energy = team.energy,
			metal_capacity = team.metal_capacity,
			energy_capacity = team.energy_capacity,
			metal_income = team.metal_income,
			energy_income = team.energy_income,
			metal_revenue = team.metal_revenue,
			metal_expense = team.metal_expense,
			energy_revenue = team.energy_revenue,
			energy_expense = team.energy_expense,
		})
	end
end

local function broadcast_resources()
	for _, player in Players:GetPlayers() do
		local team_id = players.team_of(player)
		if team_id == nil then
			continue
		end
		local team = state.get_team(team_id)
		if team == nil then
			continue
		end
		team_updated:FireClient(player, {
			metal = team.metal,
			energy = team.energy,
			metal_capacity = team.metal_capacity,
			energy_capacity = team.energy_capacity,
			metal_income = team.metal_income,
			energy_income = team.energy_income,
			metal_revenue = team.metal_revenue,
			metal_expense = team.metal_expense,
			energy_revenue = team.energy_revenue,
			energy_expense = team.energy_expense,
		})
	end
end

-- One simulation step. Work is gathered first and settled afterwards so that a resource stall is
-- shared fairly between every builder instead of being decided by iteration order.
local function step(delta: number)
	profiler.mark "flush"
	-- anything a remote handler created between steps joins the world before this step reads it
	state.flush()

	profiler.mark "wind"
	wind.tick(delta)
	profiler.mark "economy"
	flows.begin_tick()
	economy.accrue(delta)
	-- before the goals are cleared below: the scavengers read last tick's to tell which units are stuck
	profiler.mark "scavengers"
	scavengers.tick(delta)

	profiler.mark "begin_tick"
	construction.begin_tick()
	reclaim.begin_tick()
	resurrection.begin_tick()
	movement.begin_tick()
	-- before orders.tick(), so a fight order's has_target check and this tick's actual shot share
	-- one fresh target grid and one cached pick_target result instead of each scanning from scratch
	combat.begin_tick()

	profiler.mark "production"
	production.tick(delta)
	profiler.mark "drones"
	drones.tick(delta)
	profiler.mark "orders"
	orders.tick(delta)

	profiler.mark "construction"
	construction.resolve(delta)
	construction.decay(delta)
	profiler.mark "reclaim_resurrection"
	reclaim.resolve(delta)
	resurrection.resolve(delta)

	profiler.mark "movement"
	movement.tick(delta)
	-- whatever is in water it cannot stand in, however it got there, is losing its life to it
	profiler.mark "drowning"
	drowning.tick(delta)
	-- whatever mends itself does
	profiler.mark "autoheal"
	autoheal.tick(delta)
	-- what a transport carries hangs from it where it has moved to
	profiler.mark "transport"
	transport.tick()
	profiler.mark "combat"
	combat.tick(delta)
	profiler.mark "shields"
	shields.tick(delta)
	profiler.mark "projectiles"
	projectiles.tick(delta, combat.apply_damage)
	-- every crater this step made is drawn and sent once, now that nothing more will be blown up until the next
	profiler.mark "deformation"
	deformation.flush()

	profiler.mark "reap"
	for _, id in state.reap() do
		instances.destroy(id)
		production.forget(id)
		combat.forget(id)
		scavengers.forget(id)
		movement.forget(id)
		docking.forget(id)
		-- a transport that is gone takes what it was carrying with it
		state.drop_hold(id)
	end
	-- entities created during this step join the world now that nothing is iterating it
	profiler.mark "flush"
	state.flush()
	profiler.mark "entity_count"
	profiler.sample_entities()
	profiler.mark(nil)
	profiler.step_done()
end

local function init()
	-- This is an RTS: players command units from a camera and never have an avatar.
	Players.CharacterAutoLoads = false

	heightmap.initialize(MAP_SEED, MAP_PRESET)
	passability.initialize()
	metal_spots.initialize(MAP_SEED)
	wind.init()
	Workspace:SetAttribute("map_seed", MAP_SEED)
	Workspace:SetAttribute("map_preset", MAP_PRESET)

	lighting.init()
	terrain.render()
	deformation.init()

	commands.init()
	scavengers.init()

	-- Lets a Studio MCP client run /benchmark unattended: set the "AutoBenchmark" attribute on
	-- Workspace before starting a Run (no player needed - the sim steps off Heartbeat regardless),
	-- and this prints the report between sentinel lines. TestService has no supported way to end a
	-- Play-test session from server code, so a caller has to start Run, poll the output for
	-- BENCHMARK_END, and stop the session itself from there (as well as read what is between).
	if RunService:IsStudio() and Workspace:GetAttribute("AutoBenchmark") == true then
		task.spawn(function()
			task.wait(1)
			print "BENCHMARK_BEGIN"
			local ok, err = pcall(benchmark.run, print)
			if not ok then
				print(`BENCHMARK_ERROR: {err}`)
			end
			print "BENCHMARK_END"
		end)
	end

	Players.PlayerAdded:Connect(on_player_added)
	Players.PlayerRemoving:Connect(function(player: Player)
		players.forget(player)
	end)
	for _, player in Players:GetPlayers() do
		on_player_added(player)
	end

	RunService.Heartbeat:Connect(function(delta: number)
		if pause.is_paused() then
			return
		end

		local steps = 0
		if warp.is_warping() then
			-- real time is not being tracked toward anything while warping - every step is owed
			-- right away, not caught up on later - so a hitch right after warp turns off would
			-- otherwise replay as a burst of catch-up steps for time that was never real
			accumulator = 0
			local budget_ends_at = os.clock() + WARP_TIME_BUDGET
			while steps < WARP_MAX_STEPS and os.clock() < budget_ends_at do
				steps += 1
				step(config.TICK_DELTA)
			end
		else
			accumulator += delta
			-- cap catch-up so a long hitch does not spiral into a burst of steps
			while accumulator >= config.TICK_DELTA and steps < 5 do
				accumulator -= config.TICK_DELTA
				steps += 1
				step(config.TICK_DELTA)
			end
		end
		if steps > 0 then
			profiler.mark "instances_sync"
			instances.sync()
			profiler.mark(nil)
		end

		broadcast_timer += delta
		if broadcast_timer >= RESOURCE_BROADCAST_INTERVAL then
			broadcast_timer = 0
			profiler.mark "broadcast_resources"
			broadcast_resources()
			profiler.mark(nil)
		end
	end)
end

init()
