-- Server entry point: starts the session that is played (session_config.luau, bootstrap.luau), and then, unless a test
-- has the simulation to itself, runs the fixed-step simulation on the engine's clock.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local switches = require(ReplicatedStorage.Shared.switches)

local session_config = require(script.session_config)
local bootstrap = require(script.bootstrap)
local instances = require(script.instances)
local warp = require(script.warp)
local profiler = require(script.profiler)
local pregame = require(script.pregame)
local roblox_teams = require(script.roblox_teams)
local sharing = require(script.sharing)
local missions = require(script.missions)
local simulation = require(script.simulation)
local team_updates = require(script.team_updates)
local test_request = require(script.test_request)
-- The tests are only loaded into a session a Studio test was started in, never into a live server.
local tests = if test_request.request ~= nil then require(script.tests) else nil

local RESOURCE_BROADCAST_INTERVAL = 0.2

-- A hitch longer than this many steps is not caught up on: the steps it owes past these are dropped, so that a long one
-- does not spiral into a burst of steps that makes the next frame longer still.
local MAX_CATCHUP_STEPS = 5

-- While warping, how much real time each Heartbeat may spend running steps back to back before it
-- has to yield and let the engine schedule the next one - not a step count, since how many steps fit
-- in that time depends entirely on what is actually happening in the game right now.
local WARP_TIME_BUDGET = 0.15
-- An absolute cap regardless of the time budget, so a pathologically slow step() cannot still hold a
-- single Heartbeat for a very long time.
local WARP_MAX_STEPS = 500

-- How many seconds of the game pass in a second of real time is published as game_phase's `sim_rate`, so that
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
	game_phase.set_sim_rate(shown)
end

-- Runs the steps this frame owes the simulation. Returns how many it ran.
local function run_steps(delta: number): number
	local steps = 0
	if warp.is_warping() then
		-- real time is not being tracked toward anything while warping - every step is owed
		-- right away, not caught up on later - so a hitch right after warp turns off would
		-- otherwise replay as a burst of catch-up steps for time that was never real
		accumulator = 0
		local budget_ends_at = os.clock() + WARP_TIME_BUDGET
		-- a warp for a set number of ticks stops on exactly that many, even partway through a frame
		while steps < WARP_MAX_STEPS and os.clock() < budget_ends_at and warp.take_tick() do
			steps += 1
			simulation.step(tick_rate.TICK_DELTA)
		end
		return steps
	end
	accumulator += delta
	while accumulator >= tick_rate.TICK_DELTA and steps < MAX_CATCHUP_STEPS do
		accumulator -= tick_rate.TICK_DELTA
		steps += 1
		simulation.step(tick_rate.TICK_DELTA)
	end
	return steps
end

local function on_heartbeat(delta: number)
	-- nothing steps until every player is ready and the countdown is out
	pregame.tick()
	-- Roblox's teams follow the game's, for team chat, before the game has begun and while it is paused too
	roblox_teams.sync()
	-- and once it is over it keeps going, for anyone who would rather play on than look at the end screen (see
	-- client/ui/victory_screen.luau)
	if game_phase.has_begun() == false or switches.is_on "paused" then
		publish_sim_rate(0)
		return
	end

	local warping = warp.is_warping()
	local steps = run_steps(delta)
	publish_sim_rate(if warping and delta > 0 then steps * tick_rate.TICK_DELTA / delta else 1)
	if steps > 0 then
		profiler.mark "instances_sync"
		instances.sync()
		profiler.mark(nil)
	end

	broadcast_timer += delta
	if broadcast_timer >= RESOURCE_BROADCAST_INTERVAL then
		broadcast_timer = 0
		profiler.mark "broadcast_resources"
		team_updates.broadcast()
		-- the player list, which shows allies' banks, keeps pace with the resource bar, and so does the mission's HUD
		sharing.broadcast()
		missions.publish()
		profiler.mark(nil)
	end
end

local session = session_config.resolve()
bootstrap.start(session)

-- A session Studio started to run a test runs that once everything is ready, and a test that steps the simulation
-- itself has it to itself: the loop never starts.
local test = session.test
if tests ~= nil and test ~= nil and tests.begin(test, simulation.step) then
	return
end
RunService.Heartbeat:Connect(on_heartbeat)
