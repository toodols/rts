--!strict
-- One step of the game's simulation: everything that happens in a tick, in the order it happens, as one list of
-- phases. The server's loop (init.server.luau) runs it off Heartbeat, a test (server/tests) a tick at a time, and the
-- headless AI arena (tools/ai_arena) outside Roblox altogether; all three run this same step, so what one of them finds
-- holds for the others.
--
-- The core of the simulation is listed here by name. What a game mode, a mission or a skin does every tick is not the
-- simulation's business, so those phases are slots, which whoever starts the server hands their handlers for, all of
-- them, before the first step (`init`, from bootstrap.luau).
--
-- Every phase is timed under its own name (server/profiler.luau), so where a step's time goes is read off the list.

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local flows = require(script.Parent.flows)
local wind = require(script.Parent.wind)
local construction = require(script.Parent.construction)
local work = require(script.Parent.work)
local production = require(script.Parent.production)
local drones = require(script.Parent.drones)
local drowning = require(script.Parent.drowning)
local autoheal = require(script.Parent.autoheal)
local emp = require(script.Parent.emp)
local movement = require(script.Parent.movement)
local targeting = require(script.Parent.targeting)
local weapons = require(script.Parent.weapons)
local interceptors = require(script.Parent.interceptors)
local spatial = require(script.Parent.spatial)
local deaths = require(script.Parent.deaths)
local self_destruct = require(script.Parent.self_destruct)
local shields = require(script.Parent.shields)
local transport = require(script.Parent.transport)
local projectiles = require(script.Parent.projectiles)
local deformation = require(script.Parent.deformation)
local orders = require(script.Parent.orders)
local orbits = require(script.Parent.orbits)
local possession = require(script.Parent.possession)
local ai = require(script.Parent.ai)
local paths = require(script.Parent.paths)
local profiler = require(script.Parent.profiler)
local outbox = require(script.Parent.outbox)
local notifications = require(script.Parent.notifications)

-- What another module does every tick in its place in the step: the scavengers, a campaign mission, a game between
-- players, a skin's look.
export type Slot = "scavengers" | "missions" | "conquest" | "skins"

type Run = (delta: number) -> ()

-- Every slot's handler.
export type Slots = {
	scavengers: Run,
	missions: Run,
	conquest: Run,
	skins: Run,
}

type Phase = {
	name: string,
	run: Run?,
	-- for a slot, whose `run` is handed in
	slot: Slot?,
}

local handlers: Slots? = nil

-- Everything in a step, in order.
local PHASES: { Phase } = {
	-- every asker's share of routes starts over
	{ name = "paths", run = paths.begin_step },
	{ name = "wind", run = wind.tick },
	{ name = "flows", run = flows.begin_tick },
	{ name = "economy", run = economy.accrue },
	-- what the scavengers decide, as what the AI decides below, is what their units do this step
	{ name = "scavengers", slot = "scavengers" },
	-- what the AI decides is what its units do this step
	{ name = "ai", run = ai.tick },
	-- this tick's work, goals and targets are gathered afresh from here on
	{ name = "work_begin", run = work.begin_tick },
	{ name = "movement_begin", run = movement.begin_tick },
	-- before orders, so that a fight order's has_target check and this tick's actual shot share one fresh target
	-- grid and one cached pick_target result instead of each scanning from scratch
	{ name = "spatial_begin", run = spatial.begin_tick },
	{ name = "targeting_begin", run = targeting.begin_tick },
	{ name = "production", run = production.tick },
	{ name = "drones", run = drones.tick },
	{ name = "orbits", run = orbits.begin_tick },
	{ name = "orders", run = orders.tick },
	-- what the developers piloting units ask of them that no order does, their manual weapons fired within the step
	{ name = "possession", run = possession.tick },
	-- work is gathered first and settled afterwards so that a resource stall is shared fairly between every builder
	-- instead of being decided by iteration order: building, repairing, reclaiming and raising wrecks alike
	{ name = "settle", run = economy.settle },
	{ name = "decay", run = construction.decay },
	{ name = "movement", run = movement.tick },
	-- where things stand has changed; so it does wherever else something is moved or joins the world, below
	{ name = "spatial", run = spatial.invalidate },
	-- whatever is in water it cannot stand in, however it got there, is losing its life to it
	{ name = "drowning", run = drowning.tick },
	-- whatever mends itself does
	{ name = "autoheal", run = autoheal.tick },
	-- EMP drains away, and what it stunned comes round
	{ name = "emp", run = emp.tick },
	-- what a transport carries hangs from it where it has moved to
	{ name = "transport", run = transport.tick },
	{ name = "spatial", run = spatial.invalidate },
	-- the damage taken lately fades a step's worth before anything is hit this step
	{ name = "wounds", run = deaths.tick },
	{ name = "weapons", run = weapons.tick },
	-- what was told to destroy itself and has counted down does
	{ name = "self_destruct", run = self_destruct.tick },
	{ name = "shields", run = shields.tick },
	{ name = "projectiles", run = projectiles.tick },
	{ name = "interceptors", run = interceptors.tick },
	-- every crater this step made is drawn and sent once, now that nothing more will be blown up until the next
	{ name = "deformation", run = deformation.flush },
	-- a skin's look, once this step's damage is all dealt
	{ name = "skins", slot = "skins" },
	-- the dead are cleared away, and everything forgets them
	{ name = "reap", run = state.reap },
	-- entities created during this step join the world now that nothing is iterating it; what the phases below make
	-- joins as the step ends
	{ name = "flush", run = state.flush },
	-- what a side should be told of that the step brought, enemy aircraft among it
	{ name = "notifications", run = notifications.tick },
	-- a campaign mission ends once a side has nothing left
	{ name = "missions", slot = "missions" },
	-- and a game between players once one side is left
	{ name = "conquest", slot = "conquest" },
}

-- Hands in what each slot runs. Once, before the first step.
local function init(slots: Slots)
	assert(handlers == nil, "the simulation's slots are handed in once")
	handlers = table.freeze(table.clone(slots))
end

local function step(delta: number)
	local slots = handlers
	assert(slots ~= nil, "the simulation's slots are handed in (simulation.init) before it steps")
	-- from here to the end of the step, what is made waits for the step's flush to join the world, and the game's clock
	-- reads the step's end
	state.begin_step(delta)
	for _, phase in PHASES do
		local slot: Slot? = phase.slot
		local run = if slot ~= nil then (slots :: any)[slot] :: Run else phase.run :: Run
		profiler.mark(phase.name)
		run(delta)
	end
	profiler.mark(nil)
	state.end_step()
	-- what the step brought is told to the world outside it
	outbox.deliver()
	profiler.step_done()
end

return table.freeze({
	init = init,
	step = step,
})
