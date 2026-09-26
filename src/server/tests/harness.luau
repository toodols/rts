--!strict
-- What every test is built from: the clock a test runs the game on, the teams it plays as, and the fixtures that put
-- things down, fill a team's stores, find a place on the map, turn a switch for as long as a test needs it, and stand
-- in for a player sending what their client would (`join`, `send`).
--
-- A test owns the simulation's clock: it steps the game itself, a tick at a time and as fast as it can, so that it sees
-- every tick and plays the same way every time. The clock is handed in by whoever runs the test (see init.luau): in a
-- Studio session the server's own step, and headless the arena's (tools/headless_tests).

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local order_routes = require(ReplicatedStorage.Shared.order_routes)
local switches = require(ReplicatedStorage.Shared.switches)
local teams = require(ReplicatedStorage.Shared.teams)
local developers = require(ReplicatedStorage.Shared.developers)

local remotes = require(ServerScriptService.ServerShared.remotes)

local state = require(ServerScriptService.Server.state)
local deaths = require(ServerScriptService.Server.deaths)
local alliances = require(ServerScriptService.Server.alliances)
local movement = require(ServerScriptService.Server.movement)
local players = require(ServerScriptService.Server.players)
local weapons = require(ServerScriptService.Server.weapons)
local projectiles = require(ServerScriptService.Server.projectiles)
local interceptors = require(ServerScriptService.Server.interceptors)
local flows = require(ServerScriptService.Server.flows)
local emp = require(ServerScriptService.Server.emp)
local self_destruct = require(ServerScriptService.Server.self_destruct)

type Entity = types.Entity
type Team = types.Team
type TeamId = types.TeamId
type Order = types.Order

-- What a test is started with: the arguments of `{ test = name, ... }`, the test's own defaults under them.
export type Args = { [string]: any }
-- What a test found. A check says whether it passed (`pass`); a diagnostic only reports, as does a check run with
-- arguments it has nothing to judge by, which says so (`diagnostic`).
export type Findings = { [string]: any }

-- A test, as the harness knows it. `diagnostic` ones report what they find for a person to read and have no pass; the
-- rest are checks, which must say whether they passed. `defaults` are arguments the test is started with unless asked
-- otherwise, a map preset it needs, say. `studio_only` says why a test cannot run headless (tools/headless_tests), and
-- `on_loop` that it runs on the server's own loop rather than stepping the clock itself.
export type Test = {
	run: (Args) -> Findings,
	diagnostic: boolean?,
	defaults: Args?,
	studio_only: string?,
	on_loop: boolean?,
}

-- How a test's game is moved on: `step` runs one tick of the simulation, `settle` lets whatever the engine has waiting
-- (deferred signals, delayed tasks) run, and keeps a long test from being taken for a script that hangs.
export type Clock = {
	step: (number) -> (),
	settle: () -> (),
}

-- What a team has in store and can hold, as a test sets it (`set_bank`); what is left out is left as it is.
export type Bank = {
	metal: number?,
	energy: number?,
	metal_capacity: number?,
	energy_capacity: number?,
}

-- A switch a test can turn for as long as it needs it (`with_switch`), and the value it had is put back after.
export type Switch<T> = {
	get: () -> T,
	set: (T) -> (),
}

-- The teams a test plays as. Nobody joins a test session, so no team is anyone's until a test makes it
-- (`ensure_team`); ALLY is allied with OWN by the tests that need it. BYSTANDER is a team of its own that a test puts
-- things down for, far from any AI or player, and never allies with anyone.
local OWN: TeamId = 1
local ENEMY: TeamId = 2
local ALLY: TeamId = 3
local BYSTANDER: TeamId = 99
-- The team of what belongs to nobody: rocks, trees and wrecks.
local NEUTRAL: TeamId = teams.NEUTRAL

-- Health enough that nothing a test aims at dies before the test is over.
local UNKILLABLE = 1e7
-- The test lets the engine run every this many ticks, so that a long one is not taken for a script that hangs.
local SETTLE_EVERY = 100

-- One of shared/switches' switches, as a test turns it.
local function switch_of(name: switches.Name): Switch<boolean>
	return table.freeze({
		get = function(): boolean
			return switches.is_on(name)
		end,
		set = function(on: boolean)
			switches.set(name, on)
		end,
	})
end

local NOCOST = switch_of "nocost"
local SCAVENGERS = switch_of "scavengers"
local ALLY_GRIEFING: Switch<boolean> = table.freeze({
	get = alliances.is_ally_griefing,
	set = alliances.set_ally_griefing,
})

-- The user id the next player a test seats is given (`join`); real ones are never this low.
local first_fake_user = -1000

-- The clock the test being run steps, and how many seconds of game it has run.
local clock: Clock? = nil
local sim_time = 0
local ticks_run = 0

-- Starts a test's clock, `given`. The world it plays in was set up as the test asked when the session started (see
-- server/session_config.luau's `unplayed`): the scavengers off unless it hands in a match, which has them as it says, the
-- rocks and trees taken away unless it asks for `scenery`, and what the game leaves to chance rolled from `random_seed`
-- if it gives one.
local function start(given: Clock)
	clock = given
	sim_time = 0
	ticks_run = 0
end

local function now(): number
	return sim_time
end

-- Lets whatever the engine has waiting run.
local function settle()
	(clock :: Clock).settle()
end

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

-- Runs the game on for `seconds`, calling `each` after every tick.
local function advance(seconds: number, each: (() -> ())?)
	local running = clock :: Clock
	for _ = 1, math.round(seconds / tick_rate.TICK_DELTA) do
		running.step(tick_rate.TICK_DELTA)
		sim_time += tick_rate.TICK_DELTA
		ticks_run += 1
		if each ~= nil then
			each()
		end
		if ticks_run % SETTLE_EVERY == 0 then
			running.settle()
		end
	end
end

-- Runs the game on until `entity` has no orders left, or for `seconds` at most, calling `each` after every tick,
-- and returns whether its orders ran out.
local function until_idle(entity: Entity, seconds: number, each: (() -> ())?): boolean
	local deadline = sim_time + seconds
	while sim_time < deadline do
		advance(tick_rate.TICK_DELTA, each)
		if #entity.orders == 0 then
			return true
		end
	end
	return false
end

-- Team `team_id`, made first if nobody has made it: nobody joins a test session, so nobody's team is made for them.
local function ensure_team(team_id: TeamId): Team
	return state.get_team(team_id) or state.create_team(team_id)
end

-- Sets what team `team_id` can hold and has in store, within what it can hold. This is the one place a test writes a
-- team's stores, for a scenario that needs them empty, full or just so.
local function set_bank(team_id: TeamId, bank: Bank)
	local team = ensure_team(team_id)
	team.metal_capacity = bank.metal_capacity or team.metal_capacity
	team.energy_capacity = bank.energy_capacity or team.energy_capacity
	team.metal = math.clamp(bank.metal or team.metal, 0, team.metal_capacity)
	team.energy = math.clamp(bank.energy or team.energy, 0, team.energy_capacity)
end

-- Fills team `team_id`'s stores.
local function fill_bank(team_id: TeamId)
	local team = ensure_team(team_id)
	set_bank(team_id, { metal = team.metal_capacity, energy = team.energy_capacity })
end

-- Turns `switch` to `value` while `run` runs, and back to what it was afterwards, even if `run` fails.
local function with_switch<T>(switch: Switch<T>, value: T, run: () -> ())
	local was = switch.get()
	switch.set(value)
	local problem: any = nil
	local ok = xpcall(run, function(message: any)
		problem = message
	end)
	switch.set(was)
	if ok == false then
		error(problem, 0)
	end
end

-- Something of `def_name`'s, finished, standing on the ground at (x, z).
local function spawn(def_name: string, team: TeamId, x: number, z: number): Entity
	return state.create_entity(def_name, team, heightmap.ground_position(x, z), 0, "active")
end

-- Something of `def_name`'s, finished, where it rests at (x, z): on the ground, on the water or under it, as it would
-- stand there.
local function spawn_resting(def_name: string, team: TeamId, x: number, z: number): Entity
	local def = unit_defs.get(def_name)
	local y = surface.height(def, x, z) + unit_defs.collider_height(def) / 2
	return state.create_entity(def_name, team, Vector3.new(x, y, z), 0, "active")
end

local function unkillable(entity: Entity): Entity
	entity.health = UNKILLABLE
	entity.max_health = UNKILLABLE
	return entity
end

-- How much an unkillable thing has lost.
local function damage_to(entity: Entity): number
	return UNKILLABLE - entity.health
end

-- A reclaimable of `def_name` lying on the ground at (x, z), as `scenery` lays them.
local function lay(def_name: string, x: number, z: number): Entity
	local def = unit_defs.get(def_name)
	local at = surface.position(def, x, z) + Vector3.new(0, unit_defs.collider_height(def) / 2, 0)
	return state.create_reclaimable(def_name, at, 0)
end

-- The wreck of a `def_name` that stood at (x, z).
local function wreck_of(def_name: string, x: number, z: number): Entity
	return state.create_wreck(def_name, heightmap.ground_position(x, z), 0)
end

-- A player seated on team `team_id` (made if nobody has made it), a developer if `developer` says, for a test to send
-- what their client would (`send`). Their team is held to what they have unlocked, as a player's is
-- (server/unlocks.luau): a new player's, the campaign's starting unlocks. Nobody joins a test session, so this stands
-- in for one: a table with what the game asks of a Player (their ids and names, where they are, their attributes),
-- which the game is only ever handed, as it is handed a real one.
local function join(team_id: TeamId, developer: boolean?): Player
	first_fake_user -= 1
	local user_id = first_fake_user
	local attributes = Instance.new "Folder"
	local player = {
		UserId = user_id,
		Name = `tester{-user_id}`,
		DisplayName = `Tester {-user_id}`,
		Parent = Players,
		GetAttribute = function(_self: any, key: string): any
			return attributes:GetAttribute(key)
		end,
		SetAttribute = function(_self: any, key: string, value: any)
			attributes:SetAttribute(key, value)
		end,
		GetAttributeChangedSignal = function(_self: any, key: string): RBXScriptSignal
			return attributes:GetAttributeChangedSignal(key)
		end,
	}
	local seated = (player :: any) :: Player
	remotes.stand_in(seated)
	developers.publish(seated, developer == true)
	players.assign(seated, team_id)
	return seated
end

-- Sends what `player`'s client would on the remote `remote_name` (a remote of ReplicatedStorage.Shared), to the handler
-- the server hears it with, read and limited as one from a client is (server_shared/remotes.luau).
local function send(remote_name: string, player: Player, ...: any)
	remotes.deliver((ReplicatedStorage.Shared :: any)[remote_name], player, ...)
end

-- A line a command bar command logged, as pow shows it.
export type Log = { type: string, value: any }

-- The command bar's command `name`, as the pow_commands module `registers` (server/pow_commands) makes it, for a test
-- to run as pow would: the returned function runs it with `args`, given by `executor` (nobody, for none), and returns
-- what it logged, in order.
local function command(registers: (extras: any) -> (), name: string): (args: { any }, executor: Player?) -> { Log }
	local registered = { commands = {}, types = {}, permission_types = {} }
	registers(registered)
	local found = (registered.commands :: any)[name]
	assert(found ~= nil, `there is no command "{name}"`)
	return function(args: { any }, executor: Player?): { Log }
		local logs: { Log } = {}
		found.server_run({
			args = args,
			executor = executor,
			log = function(_self: any, log: Log)
				table.insert(logs, log)
			end,
		})
		return logs
	end
end

-- What the tests look in on that the game keeps to itself.

-- How many shots weapon `index` of `entity_id` has fired (server/weapons.luau).
local function shots_of(entity_id: types.EntityId, index: number): number
	return weapons.shots_of(entity_id, index)
end

-- Every rocket in flight (server/projectiles.luau).
local function in_flight(): { projectiles.Projectile }
	return projectiles.in_flight()
end

-- Every anti-nuke interceptor in flight (server/interceptors.luau).
local function interceptors_in_flight(): { interceptors.Interceptor }
	return interceptors.in_flight()
end

-- What `entity_id` is making or spending this tick (server/flows.luau).
local function flow_of(entity_id: types.EntityId): flows.Flow?
	return flows.get(entity_id)
end

-- How many seconds `entity` stays stunned (server/emp.luau), nil when it is not.
local function stun_left(entity: Entity): number?
	return emp.seconds_left(entity)
end

-- Seconds until `id` destroys itself (server/self_destruct.luau), nil when it is not counting down.
local function countdown_left(id: types.EntityId): number?
	return self_destruct.seconds_left(id)
end

-- Everything the player `player` (`join`) has been told on the remote `remote_name`, oldest first, each as the arguments
-- it was sent with.
local function told(player: Player, remote_name: string): { { any } }
	return remotes.told(player, remote_name)
end

-- Takes everything off the map and lets the step clear it away.
local function clear_world()
	for _, entity in state.all() do
		deaths.destroy(entity, "removed")
	end
	advance(tick_rate.TICK_DELTA)
end

-- The commander of team `team`, if it has one standing.
local function commander_of(team: TeamId): Entity?
	for _, entity in state.all() do
		if entity.alive and entity.team == team and unit_defs.is_commander(entity.def) then
			return entity
		end
	end
	return nil
end

-- How many of each def team `team` has, finished or not.
local function counts_of(team: TeamId): { [string]: number }
	local counts: { [string]: number } = {}
	for _, entity in state.all() do
		if entity.alive and entity.team == team then
			counts[entity.def_name] = (counts[entity.def_name] or 0) + 1
		end
	end
	return counts
end

-- Whether the water is at least `depth` deep at (x, z) and all round it out to `radius`.
local function deep_all_round(x: number, z: number, depth: number, radius: number): boolean
	if heightmap.water_depth(x, z) < depth then
		return false
	end
	for _, reach in { radius / 2, radius } do
		for index = 0, 15 do
			local angle = index * math.pi / 8
			if heightmap.water_depth(x + math.cos(angle) * reach, z + math.sin(angle) * reach) < depth then
				return false
			end
		end
	end
	return true
end

-- Somewhere on the map, searched for on a grid, where `accept(x, z)` holds, or nil if nowhere does.
local function find_spot(accept: (number, number) -> boolean): Vector3?
	local extent = math.min(heightmap.half_extents()) - 60
	for x = -extent, extent, 8 do
		if x % 200 == 0 then
			settle()
		end
		for z = -extent, extent, 8 do
			if accept(x, z) then
				return Vector3.new(x, 0, z)
			end
		end
	end
	return nil
end

-- Somewhere in open deep water, where ships and submarines can fight with room round them; the test fails if there
-- is none on the map.
local function open_sea(): Vector3
	local sea = find_spot(function(x: number, z: number): boolean
		return deep_all_round(x, z, 8, 70)
	end)
	assert(sea ~= nil, "no open deep water on this map")
	return sea
end

-- `order` for `entity` with its way laid ahead of it the way a player's is: the client works out the waypoints and the
-- server checks them, with the same functions (shared/order_routes.luau). Also how many waypoints were sent.
local function player_route(entity: Entity, order: Order): ({ Order }, number)
	local destination = order.position
	if order.target_id ~= nil then
		local target = state.get(order.target_id)
		destination = if target ~= nil then target.position else destination
	end
	if destination == nil then
		return { order }, 0
	end
	local def = entity.def
	local waypoints =
		order_routes.waypoints(def, entity.position, order.kind, order.launch == true, destination, order.radius)
	return order_routes.along(def, order, waypoints), #waypoints
end

-- How long `entity` spends trying to go somewhere and getting nowhere, a tick at a time: `watch()` after every tick
-- adds the tick if it has a goal and barely moved, and `seconds()` reads the total.
local function stuck_watch(entity: Entity): (() -> (), () -> number)
	local stuck = 0
	local last = entity.position
	local function watch()
		local moved = (entity.position - last).Magnitude
		last = entity.position
		if movement.had_goal(entity.id) and moved < 0.05 * tick_rate.TICK_DELTA then
			stuck += tick_rate.TICK_DELTA
		end
	end
	local function seconds(): number
		return stuck
	end
	return watch, seconds
end

return table.freeze({
	OWN = OWN,
	ENEMY = ENEMY,
	ALLY = ALLY,
	BYSTANDER = BYSTANDER,
	NEUTRAL = NEUTRAL,
	UNKILLABLE = UNKILLABLE,
	NOCOST = NOCOST,
	SCAVENGERS = SCAVENGERS,
	ALLY_GRIEFING = ALLY_GRIEFING,
	start = start,
	now = now,
	settle = settle,
	round = round,
	advance = advance,
	until_idle = until_idle,
	ensure_team = ensure_team,
	set_bank = set_bank,
	fill_bank = fill_bank,
	with_switch = with_switch,
	spawn = spawn,
	spawn_resting = spawn_resting,
	unkillable = unkillable,
	damage_to = damage_to,
	lay = lay,
	wreck_of = wreck_of,
	clear_world = clear_world,
	commander_of = commander_of,
	counts_of = counts_of,
	deep_all_round = deep_all_round,
	find_spot = find_spot,
	open_sea = open_sea,
	player_route = player_route,
	stuck_watch = stuck_watch,
	join = join,
	send = send,
	told = told,
	command = command,
	shots_of = shots_of,
	in_flight = in_flight,
	interceptors_in_flight = interceptors_in_flight,
	flow_of = flow_of,
	stun_left = stun_left,
	countdown_left = countdown_left,
})
