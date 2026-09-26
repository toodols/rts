--!strict
-- Blockade, the sixth mission, on the channel again (shared/map_designs/channel.luau), just after Channel Crossing. The
-- enemy's island outpost, line and base are wrecks now, where they stood (mission_forces.CHANNEL_ENEMY), for the player
-- to reclaim or raise. The player holds the west shore with a harbour base (mission_forces.BLOCKADE_BASE), which goes
-- down beside their commander once the commander has (`on_commander_down`), and so starts the mission's clock. Played
-- together, the one team has it all.
--
-- The player has BLOCKADE_LAYOUT.prep_seconds to prepare. Then the enemy's fleets sail through the channel in waves, at
-- the times the waves give (mission_forces' BLOCKADE_WAVES, or in the hard mode BLOCKADE_HARD_WAVES, twelve rather than
-- seven, with cruisers), or sooner once one has been sunk (`on_enemy_counted`, CLEARED_SECONDS), each bigger than the
-- last. The ships of one come in over SPAWN_SECONDS at the channel's north end, half at the head of each strait
-- (LANES), and each is sent down its strait to the south end: a move, not a fight, so it fires at whatever it passes
-- but stops for nothing, and the player is never its target. One that stops short is sent on again. One that reaches
-- the south end (ESCAPE_Z) has got through: it leaves the map and is counted.
--
-- The mission is won once all of the final wave has come in and the enemy has nothing left on the map (`is_beaten`), and
-- lost once BLOCKADE_LAYOUT.escape_limit ships have got through (`lost`), or the player's commander is destroyed, as any
-- other is.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local surface = require(ReplicatedStorage.Shared.surface)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local mission_forces = require(ReplicatedStorage.Shared.mission_forces)

local state = require(ServerScriptService.Server.state)
local spawning = require(ServerScriptService.Server.spawning)
local orders = require(ServerScriptService.Server.orders)
local notifications = require(ServerScriptService.Server.notifications)
local paths = require(ServerScriptService.Server.paths)
local deaths = require(ServerScriptService.Server.deaths)
local snapshot = require(ServerScriptService.Server.snapshot)

local kit = require(script.Parent.kit)

type Entity = types.Entity
type EntityId = types.EntityId
type TeamId = types.TeamId
type Order = types.Order
type Wave = mission_forces.Wave

local LAYOUT = mission_forces.BLOCKADE_LAYOUT

-- The line under the result once too many have got through.
local ESCAPED_LOST = "Too many ships got through"
-- The player's metal spots on land are those west of PLAYER_SHORE_X; the enemy's old ones those east of ENEMY_SHORE_X.
local PLAYER_SHORE_X = -150
local ENEMY_SHORE_X = 150
-- The ways through the channel, north to south, a strait each: where a fleet comes in and where it makes for (the
-- map's points).
local LANES = {
	{ from = "sea_north", to = "sea_south" },
	{ from = "east_north", to = "east_south" },
}
-- A ship south of this has got through.
local ESCAPE_Z = 235
-- Which way a ship faces as it comes in: south, down the channel.
local SOUTH = 0
-- How often, in seconds of game, the waves' ships are looked over for any through or wanting sending on.
local DIRECT_SECONDS = 1
-- What the waves ask the routes of (server/paths.luau).
local ASKER: paths.Asker = table.freeze({ name = "blockade", share = 6, max_expansions = 8000 })
-- A ship sent on is not sent again for this long, however soon it stops.
local RESEND_SECONDS = 10
-- How long after a wave has been sunk the next one comes, at most.
local CLEARED_SECONDS = 5
-- A wave comes in over this many seconds (times the pace), a ship at a time at each strait.
local SPAWN_SECONDS = 6

local began_at: number? = nil
local prep_seconds = LAYOUT.prep_seconds
local pace = 1
local waves: { Wave } = mission_forces.BLOCKADE_WAVES
local arrived = 0
local escaped = 0
local enemy_team: TeamId? = nil
local direct_timer = 0
local next_send: { [EntityId]: number } = {}
-- The strait each of the waves' ships is going down, an index into LANES.
local lane_of: { [EntityId]: number } = {}
local furnished: { [TeamId]: boolean } = {}
local to_come: { { at: number, def_name: string, lane: number } } = {}
-- The move orders the ships of the wave coming in are sent by, by def name and strait ("riptide:1").
local routes: { [string]: { Order } } = {}

local function is_player_team(team_id: TeamId): boolean
	return kit.is_players(team_id, enemy_team)
end

local function mission_time(): number
	return if began_at ~= nil then state.now() - began_at else 0
end

local function arrival_time(index: number): number
	return prep_seconds + waves[index].at * pace
end

-- Where a ship of `def` on strait `lane` makes for: the strait's south end.
local function exit_position(def: types.EntityDef, lane: number): Vector3
	local at = mission_map.here(LANES[lane].to)
	return surface.position(def, at.X, at.Y)
end

local function move_route(def: types.EntityDef, from: Vector3, to: Vector3): { Order }?
	local route = paths.route(ASKER, nil, def, from, to, "move")
	if route == nil then
		return nil
	end
	return paths.or_straight(route, def, to, "move")
end

-- Puts one of a wave's ships, of `def_name`, down at the head of strait `lane` and sends it down it.
local function spawn_one(def_name: string, lane: number)
	local def = unit_defs.get(def_name)
	local arrival = mission_map.here(LANES[lane].from)
	local at = surface.position(def, arrival.X, arrival.Y)
	local key = `{def_name}:{lane}`
	local chain: { Order }? = routes[key]
	if chain == nil then
		local fresh = move_route(def, at, exit_position(def, lane))
		if fresh ~= nil then
			routes[key] = fresh
		end
		chain = fresh
	end
	local unit = spawning.spawn_near(def_name, enemy_team :: TeamId, at, SOUTH)
	if unit == nil then
		warn(`Blockade found no room for its {def_name} at {arrival}`)
		return
	end
	lane_of[unit.id] = lane
	if chain ~= nil then
		orders.issue(unit, table.clone(chain), false, false)
		next_send[unit.id] = mission_time() + RESEND_SECONDS
	end
end

local function release_due()
	local now = mission_time()
	local index = 1
	while index <= #to_come do
		local each = to_come[index]
		if each.at <= now then
			table.remove(to_come, index)
			spawn_one(each.def_name, each.lane)
		else
			index += 1
		end
	end
end

-- Wave `index` arrives: its ships start to come in at the head of each strait, a ship at a time at each over
-- SPAWN_SECONDS, half of each def at each (the odd one down the west strait), the heaviest first.
local function spawn_wave(index: number)
	local now = mission_time()
	table.clear(routes)
	local by_lane: { { string } } = {}
	for lane in LANES do
		by_lane[lane] = {}
	end
	for _, each in waves[index].units do
		for lane in LANES do
			local here = each.count // #LANES + (if lane <= each.count % #LANES then 1 else 0)
			for _ = 1, here do
				table.insert(by_lane[lane], each.def_name)
			end
		end
	end
	for lane, names in by_lane do
		local gap = SPAWN_SECONDS * pace / math.max(#names, 1)
		for order, def_name in names do
			table.insert(to_come, { at = now + (order - 1) * gap, def_name = def_name, lane = lane })
		end
	end
	arrived = index
	local final = index == #waves
	-- the ping is on the channel's north end, between the straits' heads
	local heads = (mission_map.here(LANES[1].from) + mission_map.here(LANES[2].from)) / 2
	for team_id in state.all_teams() do
		if is_player_team(team_id) then
			notifications.to_team(team_id, {
				kind = if final then "final_wave" else "wave",
				amount = index,
				at = heightmap.ground_position(heads.X, heads.Y),
			})
		end
	end
end

-- Takes whichever of the waves' ships have got through off the map, counting them, and sends on any that have stopped
-- short, down their strait.
local function direct()
	local now = mission_time()
	for _, unit in state.all() do
		if unit.alive == false or unit.team ~= enemy_team or unit.kind ~= "unit" then
			continue
		end
		if unit.position.Z >= ESCAPE_Z then
			-- the mission is lost with the one that makes the limit; the count stops there
			if escaped >= LAYOUT.escape_limit then
				return
			end
			escaped += 1
			deaths.destroy(unit, "removed")
			continue
		end
		if #unit.orders > 0 or (next_send[unit.id] or 0) > now then
			continue
		end
		local chain = move_route(unit.def, unit.position, exit_position(unit.def, lane_of[unit.id] or 1))
		if chain == nil then
			return
		end
		orders.issue(unit, chain, false, false)
		next_send[unit.id] = now + RESEND_SECONDS
	end
end

local function reset()
	began_at = nil
	prep_seconds = LAYOUT.prep_seconds
	pace = 1
	waves = mission_forces.BLOCKADE_WAVES
	arrived = 0
	escaped = 0
	enemy_team = nil
	direct_timer = 0
	table.clear(next_send)
	table.clear(lane_of)
	table.clear(furnished)
	table.clear(to_come)
	table.clear(routes)
end

-- Channel Crossing's enemy, wrecked where it stood, and an enemy playing as `enemy` with nothing yet, for the waves to
-- play as, the hard mode's in its hard mode. The player's base goes down with their commander (`on_commander_down`).
local function setup(enemy: TeamId, playing: kit.Playing)
	reset()
	waves = if playing.hard then mission_forces.BLOCKADE_HARD_WAVES else mission_forces.BLOCKADE_WAVES
	enemy_team = enemy
	for _, center in
		kit.extractor_sites(function(spot: Vector3): boolean
			return spot.X > ENEMY_SHORE_X
		end, kit.WEST)
	do
		kit.place_wreck(kit.EXTRACTOR_DEF, center, kit.WEST)
	end
	for _, each in mission_forces.CHANNEL_ENEMY do
		kit.place_wreck(each.def_name, kit.standing_center(each.def_name, each.at.X, each.at.Y, kit.WEST), kit.WEST)
	end
end

-- Puts the harbour base (BLOCKADE_BASE) down for `team_id`, whose commander has just gone down, with an extractor on each
-- of the player's metal spots on land, and starts the mission's clock. Only the first team gets it: there is one
-- harbour.
local function on_commander_down(team_id: TeamId)
	if next(furnished) ~= nil then
		furnished[team_id] = true
		return
	end
	furnished[team_id] = true
	kit.place_extractors(
		team_id,
		kit.extractor_sites(function(spot: Vector3): boolean
			return spot.X < PLAYER_SHORE_X and spot.Y > 0
		end, kit.EAST),
		kit.EAST
	)
	local base: { kit.Placed } = {}
	for _, each in mission_forces.BLOCKADE_BASE do
		if each.def_name == "shipyard" then
			-- the shipyard goes in the harbour's water wherever there is room for it there
			local at = mission_map.here "harbor"
			if spawning.spawn_near(each.def_name, team_id, heightmap.ground_position(at.X, at.Y), kit.EAST) == nil then
				warn "Blockade found no room for the harbour's shipyard"
			end
		else
			table.insert(base, { def_name = each.def_name, at = each.at })
		end
	end
	kit.place_all(base, team_id, kit.EAST)
	if began_at == nil then
		began_at = state.now()
	end
end

local function tick(delta: number)
	if began_at == nil or enemy_team == nil then
		return
	end
	while arrived < #waves and mission_time() >= arrival_time(arrived + 1) do
		spawn_wave(arrived + 1)
	end
	release_due()
	direct_timer += delta
	if direct_timer >= DIRECT_SECONDS then
		direct_timer = 0
		direct()
	end
end

local function arriving(): number
	return #to_come
end

-- The enemy has nothing between its waves: it is only beaten once all of the last of them has come in.
local function is_beaten(): boolean
	return arrived >= #waves and arriving() == 0
end

-- Lost once too many have got through.
local function lost(): string?
	return if escaped >= LAYOUT.escape_limit then ESCAPED_LOST else nil
end

-- Once a wave has been sunk, the next comes CLEARED_SECONDS later if it was due any later than that.
local function on_enemy_counted(enemy_left: number)
	if began_at == nil or enemy_left > 0 or #to_come > 0 or arrived == 0 or arrived >= #waves then
		return
	end
	local due = arrival_time(arrived + 1)
	if due - mission_time() > CLEARED_SECONDS then
		began_at = state.now() - (due - CLEARED_SECONDS)
	end
end

local function hud(enemy_left: number): mission_state.Hud?
	if enemy_team == nil then
		return nil
	end
	return {
		waves = {
			wave = arrived,
			waves = #waves,
			wave_in = if arrived < #waves
				then math.max(0, math.ceil(arrival_time(arrived + 1) - mission_time()))
				else nil,
			left = enemy_left,
			escaped = escaped,
			escape_limit = LAYOUT.escape_limit,
		},
	}
end

local function retime(prep: number?, wave_pace: number?)
	prep_seconds = prep or LAYOUT.prep_seconds
	pace = wave_pace or 1
end

local function forget(id: EntityId)
	next_send[id] = nil
	lane_of[id] = nil
end

-- How many of the enemy's ships have got through.
local function escapes(): number
	return escaped
end

local handler: kit.Handler = {
	setup = setup,
	reset = reset,
	tick = tick,
	on_commander_down = on_commander_down,
	is_beaten = is_beaten,
	lost = lost,
	arriving = arriving,
	on_enemy_counted = on_enemy_counted,
	end_mode = "commanders",
	hud = hud,
	retime = retime,
	forget = forget,
}

snapshot.keep("mission_blockade", function()
	return {
		began_at = began_at,
		prep_seconds = prep_seconds,
		pace = pace,
		waves = waves,
		arrived = arrived,
		escaped = escaped,
		enemy_team = enemy_team,
		direct_timer = direct_timer,
		next_send = next_send,
		lane_of = lane_of,
		furnished = furnished,
		to_come = to_come,
		routes = routes,
	}
end, function(saved)
	began_at = saved.began_at
	prep_seconds = saved.prep_seconds
	pace = saved.pace
	waves = saved.waves
	arrived = saved.arrived
	escaped = saved.escaped
	enemy_team = saved.enemy_team
	direct_timer = saved.direct_timer
	next_send = saved.next_send
	lane_of = saved.lane_of
	furnished = saved.furnished
	to_come = saved.to_come
	routes = saved.routes
end)

return table.freeze({
	handler = table.freeze(handler),
	escapes = escapes,
})
