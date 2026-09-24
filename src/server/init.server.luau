-- Server entry point: builds the map, hands each player a starting force, and runs the fixed-step
-- simulation.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local map_presets = require(ReplicatedStorage.Shared.map_presets)

local state = require(script.state)
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
local movement = require(script.movement)
local combat = require(script.combat)
local shields = require(script.shields)
local transport = require(script.transport)
local projectiles = require(script.projectiles)
local deformation = require(script.deformation)
local orders = require(script.orders)
local instances = require(script.instances)
local commands = require(script.commands)
local pings = require(script.pings)
local players = require(script.players)
local replication = require(script.replication)
local scavengers = require(script.scavengers)
local ai = require(script.ai)
local pause = require(script.pause)
local warp = require(script.warp)
local profiler = require(script.profiler)
local benchmark = require(script.benchmark)
local studio_tests = require(script.studio_tests)
local maps = require(script.maps)
local reaper = require(script.reaper)
local match = require(script.match)
local lobby = require(script.lobby)
local sharing = require(script.sharing)
local campaign = require(script.campaign)
local skins = require(script.skins)
local donuts = require(script.donuts)
local missions = require(script.missions)
local campaign_exit = require(script.campaign_exit)
local match_stats = require(script.match_stats)

type TeamId = types.TeamId

local team_updated: RemoteEvent = ReplicatedStorage.Shared.TeamUpdated

local MAP_SEED = 1337
-- What the ground is like: a name from shared/map_presets.luau, like "highlands", "koth" or one of the BAR maps
-- ("supreme_isthmus", "hooked", "center_command", "rifted", "comet_catcher", "altair_crossing",
-- "ancient_bastion", "folsom_dam").
local MAP_PRESET = "highlands"
local RESOURCE_BROADCAST_INTERVAL = 0.2

-- While warping, how much real time each Heartbeat may spend running steps back to back before it
-- has to yield and let the engine schedule the next one - not a step count, since how many steps fit
-- in that time depends entirely on what is actually happening in the game right now.
local WARP_TIME_BUDGET = 0.15
-- An absolute cap regardless of the time budget, so a pathologically slow step() cannot still hold a
-- single Heartbeat for a very long time.
local WARP_MAX_STEPS = 500

-- How many seconds of the game pass in a second of real time is published as Workspace's `sim_rate`, so that
-- the client can fly what it draws at the game's pace: 1 normally, more while warping, 0 while paused. Warping
-- runs however many steps fit in each frame, so it is smoothed over frames, and sent only to a tenth.
local SIM_RATE_SMOOTHING = 0.1
local SIM_RATE_SNAP = 0.05

local accumulator = 0
local broadcast_timer = 0
local sim_rate = 1

local function publish_sim_rate(rate: number)
	sim_rate += (rate - sim_rate) * SIM_RATE_SMOOTHING
	if math.abs(sim_rate - rate) < SIM_RATE_SNAP then
		sim_rate = rate
	end
	local shown = math.round(sim_rate * 10) / 10
	if Workspace:GetAttribute "sim_rate" ~= shown then
		Workspace:SetAttribute("sim_rate", shown)
	end
end

local function on_player_added(player: Player)
	-- before anything is built, so the world is on its way to the client as it appears
	replication.attach(player)
	-- what they have unlocked in the campaign, the starting unlocks at once and then what is stored
	campaign.player_added(player)

	-- someone the lobby sent only to watch has no team, and so nothing to command and nowhere to start
	local team_id = if match.is_spectator(player) then nil else players.assign(player, match.team_of(player))
	player:SetAttribute("spectator", if team_id == nil then true else nil)
	-- their team wears the skin they have equipped, before their commander is put down
	skins.player_added(player)
	match.arrived(player)
	-- their commander goes down once they have chosen a start and the game has begun, or now if it already has
	lobby.player_added(player)

	local team = if team_id ~= nil then state.get_team(team_id) else nil
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
	-- what the AI decides is what its units do this step
	profiler.mark "ai"
	ai.tick(delta)

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
	-- the pool skin's donuts, once this step's damage is all dealt, so every hit pops one
	profiler.mark "donuts"
	donuts.tick(delta)

	profiler.mark "reap"
	reaper.reap()
	-- entities created during this step join the world now that nothing is iterating it
	profiler.mark "flush"
	state.flush()
	-- a campaign mission ends once a side has nothing left
	profiler.mark "missions"
	missions.tick(delta)
	profiler.mark "entity_count"
	profiler.sample_entities()
	profiler.mark(nil)
	profiler.step_done()
end

local function init()
	-- This is an RTS: players command units from a camera and never have an avatar.
	Players.CharacterAutoLoads = false

	-- A lobby's match overrides the map, the seed and the scavengers this place starts with when played straight from
	-- Studio; a Studio test may hand one in the way a lobby would, or ask for another map.
	local tested_preset = studio_tests.preset()
	-- Played straight from Studio outside a test, it may be asked to play a campaign mission (see missions.luau).
	local studio_mission = if studio_tests.requested() then nil else missions.studio_mission()
	local started = match.load(studio_tests.handed_match(), studio_mission)
	local preset = MAP_PRESET
	local seed = MAP_SEED
	if tested_preset ~= nil then
		preset = tested_preset
	elseif started ~= nil then
		preset = started.preset
		seed = started.seed
	end
	-- a BAR map its makers have not cleared is only there in Studio (see shared/bar_maps/rights.luau)
	if map_presets.presets[preset] == nil then
		preset = map_presets.DEFAULT
	end
	players.reserve(match.seated_count())
	wind.init()
	lighting.init()
	deformation.init()
	-- the meshes every rock and tree on the map is cloned from, before the map lays any out
	instances.preload()
	maps.build(seed, preset)
	-- whatever the campaign mission being played starts with, if one is
	missions.setup()

	commands.init()
	pings.init()
	sharing.init()
	skins.init()
	campaign_exit.init()
	match_stats.init()
	scavengers.init()

	-- A session a Studio plugin started to run a test runs that, and nothing else below that would get in its way
	-- (see studio_tests.luau, which can also run /benchmark and hand its report back).
	local testing = studio_tests.begin(step)

	-- Computer opponents for a game played straight from Studio: set Workspace's "AiOpponents" to how many, and each is
	-- put down at a free start once the game begins. A test puts down its own.
	local opponents = Workspace:GetAttribute "AiOpponents"
	ai.init(if testing == false and typeof(opponents) == "number" then opponents else 0)

	-- Lets a Studio MCP client run /benchmark unattended: set the "AutoBenchmark" attribute on
	-- Workspace before starting a Run (no player needed - the sim steps off Heartbeat regardless),
	-- and this prints the report between sentinel lines. A caller has to start Run, poll the output for
	-- BENCHMARK_END, and stop the session itself from there (as well as read what is between); a test
	-- session started with { test = "benchmark" } hands the report back instead, and sets nothing on the place.
	if testing == false and RunService:IsStudio() and Workspace:GetAttribute "AutoBenchmark" == true then
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

	-- Nobody plays a Studio test or a Run, the benchmark's included, so those do not wait for anyone to be ready. A
	-- playtest does, whatever else is set.
	lobby.init(testing or RunService:IsRunMode())

	Players.PlayerAdded:Connect(on_player_added)
	Players.PlayerRemoving:Connect(function(player: Player)
		lobby.player_removing(player)
		campaign.player_removing(player)
		players.forget(player)
	end)
	for _, player in Players:GetPlayers() do
		on_player_added(player)
	end

	RunService.Heartbeat:Connect(function(delta: number)
		-- a test steps the simulation itself
		if studio_tests.owns_clock() then
			return
		end
		-- nothing steps until every player is ready and the countdown is out
		lobby.tick()
		if game_phase.is_playing() == false then
			publish_sim_rate(0)
			return
		end
		if pause.is_paused() then
			publish_sim_rate(0)
			return
		end

		local steps = 0
		local warping = warp.is_warping()
		if warping then
			-- real time is not being tracked toward anything while warping - every step is owed
			-- right away, not caught up on later - so a hitch right after warp turns off would
			-- otherwise replay as a burst of catch-up steps for time that was never real
			accumulator = 0
			local budget_ends_at = os.clock() + WARP_TIME_BUDGET
			-- a warp for a set number of ticks stops on exactly that many, even partway through a frame
			while steps < WARP_MAX_STEPS and os.clock() < budget_ends_at and warp.take_tick() do
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
		publish_sim_rate(if warping and delta > 0 then steps * config.TICK_DELTA / delta else 1)
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
			-- the player list, which shows allies' banks, keeps pace with the resource bar
			sharing.broadcast()
			profiler.mark(nil)
		end
	end)
end

init()
