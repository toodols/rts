--!strict
-- The counterattack, the third mission, on the overlook's map again, just after the overlook. The enemy's base below
-- the cliff is wrecks now (mission_forces.OVERLOOK_ENEMY, but for what stood in the waves' zone, whose wrecks lie just
-- west of it, and the extractors on its spots), for the player to raise; and the player holds the plateau with the base
-- they won the overlook with (BASE), which goes down beside their commander once the commander has
-- (`on_commander_down`), and so starts the mission's clock. Played together, the first team to have its commander down
-- gets the base and each after it an army of its own. The enemy the waves play as has nothing on the field until the
-- first wave arrives.
--
-- The player has LAYOUT.prep_seconds to prepare. Then the waves come, one after another at the times the waves give
-- (mission_forces' COUNTERATTACK_WAVES, or in the hard mode COUNTERATTACK_HARD_WAVES, fifteen rather than eight, with
-- pounders and januses among them), or sooner once one has been wiped out (`on_enemy_counted`, CLEARED_SECONDS), each
-- bigger than the last and the last of them the final wave: the units of one come down a few at a time over
-- SPAWN_SECONDS at the east end of the map, half at each of the layout's arrivals, and each is sent fighting its way to
-- the player's base, the north half by the north ramp and the south half by the south. A unit that has got where it
-- was sent, or has run out of the way there,
-- is sent on at whatever of the player's is nearest, and a bomber is sent at the player's building nearest it, again
-- whenever the one it was sent at is gone. Tanks cannot climb the ramps, which are made for bots: their way up is the
-- road down the cliff's face between them (map_presets' overlook), which the pathfinder finds for them.
--
-- The enemy zone is the strip of the map east of LAYOUT.zone_x, where the waves arrive, all of every wave inside it and
-- none of the old base: whatever the player has there when a wave arrives is destroyed, and a building of theirs going
-- up there is warned of as they place it (a notification, server/notifications.luau). The mission is won once all of
-- the final wave has come down and the enemy has nothing left (`is_beaten`), and lost as any other is.
--
-- What the HUD shows of it is the zone and the waves (`hud`, shared/mission_state.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local mission_forces = require(ReplicatedStorage.Shared.mission_forces)

local state = require(ServerScriptService.Server.state)
local spawning = require(ServerScriptService.Server.spawning)
local orders = require(ServerScriptService.Server.orders)
local deaths = require(ServerScriptService.Server.deaths)
local notifications = require(ServerScriptService.Server.notifications)
local paths = require(ServerScriptService.Server.paths)
local spatial = require(ServerScriptService.Server.spatial)

local kit = require(script.Parent.kit)
local overlook = require(script.Parent.overlook)

type Entity = types.Entity
type EntityId = types.EntityId
type TeamId = types.TeamId
type Order = types.Order

-- Something of the player's base: what, and where in world (x, z), or for what stands at the edge, `back` studs west
-- of wherever the edge is at its z (mission_map.brink_x).
type BasePart = { def_name: string, at: Vector2, back: number? }

type Wave = mission_forces.Wave

local LAYOUT = mission_forces.COUNTERATTACK_LAYOUT

-- The player's base, as they won the overlook with it, on the plateau and facing east, at the cliff. The bot lab
-- stands between the commander and the edge, the solar collectors behind the commander, and the army along the edge,
-- the thugs in front where they outreach what is below, the aggravators behind them. An extractor goes on each of the
-- player's four metal spots as well. Two graverobbers, the overlook's reward, wait beside the lab to raise the old
-- base's guards.
local BASE: { BasePart } = {
	{ def_name = "bot_lab", at = Vector2.new(-38, 0), back = nil },
	{ def_name = "graverobber", at = Vector2.new(-30, -10), back = nil },
	{ def_name = "graverobber", at = Vector2.new(-30, 10), back = nil },
	{ def_name = "solar_collector", at = Vector2.new(-70, -14), back = nil },
	{ def_name = "solar_collector", at = Vector2.new(-70, 0), back = nil },
	{ def_name = "solar_collector", at = Vector2.new(-70, 14), back = nil },
	{ def_name = "solar_collector", at = Vector2.new(-62, -14), back = nil },
	{ def_name = "solar_collector", at = Vector2.new(-62, 0), back = nil },
	{ def_name = "solar_collector", at = Vector2.new(-62, 14), back = nil },
	{ def_name = "thug", at = Vector2.new(0, -15), back = 5 },
	{ def_name = "thug", at = Vector2.new(0, -9), back = 5 },
	{ def_name = "thug", at = Vector2.new(0, -3), back = 5 },
	{ def_name = "thug", at = Vector2.new(0, 3), back = 5 },
	{ def_name = "thug", at = Vector2.new(0, 9), back = 5 },
	{ def_name = "thug", at = Vector2.new(0, 15), back = 5 },
	{ def_name = "aggravator", at = Vector2.new(0, -12), back = 11 },
	{ def_name = "aggravator", at = Vector2.new(0, -4), back = 11 },
	{ def_name = "aggravator", at = Vector2.new(0, 4), back = 11 },
	{ def_name = "aggravator", at = Vector2.new(0, 12), back = 11 },
}

-- How often, in seconds of game, the waves' units are looked over for any that want sending on.
local DIRECT_SECONDS = 1
-- What the waves ask the routes of (server/paths.luau): six a step, each settling no more than 6000 cells. A unit a
-- route is refused to is sent the next time.
local ASKER: paths.Asker = table.freeze({ name = "counterattack", share = 6, max_expansions = 6000 })
-- A unit sent on is not sent again for this long, however soon it stops: a tank at the foot of the cliff stops at once,
-- having gone as far as it can, and would otherwise have its route worked out anew every look.
local RESEND_SECONDS = 10
-- How often the enemy zone is looked over for new buildings of the player's, in seconds of game, and how long after a
-- team is warned it may be warned again, so that a line of buildings dragged out there is one warning.
local ZONE_CHECK_SECONDS = 0.5
local WARN_GAP_SECONDS = 5
-- How long after a wave has been wiped out the next one comes, at most.
local CLEARED_SECONDS = 5
-- A wave comes down over this many seconds (times the pace, as the gaps between waves are), a unit at a time at each
-- arrival, rather than all at once.
local SPAWN_SECONDS = 6

-- When, by the game's clock (state.now), the player's base went down, or nil until it has; the mission's time counts from
-- there (`mission_time`).
local began_at: number? = nil
-- How long the player has to prepare, and how much longer than the waves say the gaps between them are; a Studio test
-- or the command bar changes both (`retime`).
local prep_seconds = LAYOUT.prep_seconds
local pace = 1
-- The waves of the mission being played: the hard mode's in its hard mode.
local waves: { Wave } = mission_forces.COUNTERATTACK_WAVES
-- How many waves have arrived.
local arrived = 0
local enemy_team: TeamId? = nil
local direct_timer = 0
local zone_timer = 0
-- When each of the waves' units may next be sent on, by the mission's time.
local next_send: { [EntityId]: number } = {}
-- The player's buildings in the zone that have been warned of, and when each team was last warned.
local warned: { [EntityId]: boolean } = {}
local warned_at: { [TeamId]: number } = {}
-- The teams whose base has been put down (`on_commander_down`).
local furnished: { [TeamId]: boolean } = {}
-- The units of the waves that have arrived still to come down: when (by the mission's time), what, and at which of the
-- layout's arrivals.
local to_come: { { at: number, def_name: string, side: number } } = {}
-- The fight orders the units of the wave coming down are sent by, by def name and arrival ("thug:1"), each worked out
-- for the first of them that has one.
local routes: { [string]: { Order } } = {}

local function is_player_team(team_id: TeamId): boolean
	return kit.is_players(team_id, enemy_team)
end

local function is_in_zone(position: Vector3): boolean
	return position.X >= LAYOUT.zone_x
end

-- Seconds since the player's base went down; 0 until it has.
local function mission_time(): number
	return if began_at ~= nil then state.now() - began_at else 0
end

-- When wave `index` arrives, by the mission's time.
local function arrival_time(index: number): number
	return prep_seconds + waves[index].at * pace
end

-- The middle of the player's base, where a wave is sent.
local function base_position(): Vector3
	local start = mission_map.here(mission_map.PLAYER_START)
	return heightmap.ground_position(start.X, start.Y)
end

-- The fight orders that take a unit of `def` from `from` to `to`, by the way round the cliff if it has to go round, or
-- as far as it can get when it cannot get there (straight at `to` if a route gets nowhere); nil when the waves have no
-- route left this step.
local function fight_route(def: types.EntityDef, from: Vector3, to: Vector3): { Order }?
	local route = paths.route(ASKER, nil, def, from, to, "fight")
	if route == nil then
		return nil
	end
	return paths.or_straight(route, def, to, "fight")
end

-- The player's thing nearest `from`: of their buildings only, for `buildings_only`.
local function nearest_player_thing(from: Vector3, buildings_only: boolean): Entity?
	return spatial.nearest(from, math.huge, function(entity: Entity): boolean
		return is_player_team(entity.team)
			and (entity.kind == "building" or (buildings_only == false and entity.kind == "unit"))
	end)
end

-- Sends a bomber of the waves at the player's building nearest it, or at their nearest anything once they have no
-- buildings left.
local function send_bomber(unit: Entity)
	local target = nearest_player_thing(unit.position, true) or nearest_player_thing(unit.position, false)
	if target ~= nil then
		orders.issue(unit, { { kind = "attack", target_id = target.id } }, false, false)
	end
end

-- Destroys everything the player has in the enemy zone: a wave has arrived there.
local function clear_zone()
	for _, entity in state.all() do
		if
			entity.alive
			and (entity.kind == "unit" or entity.kind == "building")
			and is_player_team(entity.team)
			and is_in_zone(entity.position)
		then
			deaths.destroy(entity, "removed")
		end
	end
end

-- Puts one of a wave's units, of `def_name`, down at arrival `side` and sends it at the player's base. The units of a
-- def at an arrival are sent by one route, worked out from there for the first of them.
local function spawn_one(def_name: string, side: number)
	local def = unit_defs.get(def_name)
	local arrival = LAYOUT.arrivals[side]
	local at = heightmap.ground_position(arrival.X, arrival.Y)
	local air = unit_defs.is_air(def)
	local chain: { Order }? = nil
	if air == false then
		local key = `{def_name}:{side}`
		chain = routes[key]
		if chain == nil then
			local fresh = fight_route(def, at, base_position())
			if fresh ~= nil then
				routes[key] = fresh
			end
			chain = fresh
		end
	end
	-- all of a wave comes down in the zone, clear of its edge
	local margin = unit_defs.collider_radius(def)
	local function in_zone(x: number, _z: number): boolean
		return x - margin >= LAYOUT.zone_x
	end
	local unit = spawning.spawn_near(def_name, enemy_team :: TeamId, at, kit.WEST, in_zone)
	if unit == nil then
		warn(`the counterattack found no room for its {def_name} at {arrival}`)
		return
	end
	if chain ~= nil then
		orders.issue(unit, table.clone(chain), false, false)
		next_send[unit.id] = mission_time() + RESEND_SECONDS
	elseif air then
		send_bomber(unit)
		next_send[unit.id] = mission_time() + RESEND_SECONDS
	end
	-- one the waves had no route left for is sent on at the next look over (`direct`)
end

-- Puts down whichever of the waves' units are due.
local function release_due()
	local now = mission_time()
	local index = 1
	while index <= #to_come do
		local each = to_come[index]
		if each.at <= now then
			table.remove(to_come, index)
			spawn_one(each.def_name, each.side)
		else
			index += 1
		end
	end
end

-- Wave `index` arrives: its units start to come down at the arrivals, a unit at a time at each over SPAWN_SECONDS, half
-- of each def at each arrival (the odd one at the first), the heaviest first, and whatever the player left in the zone
-- is gone.
local function spawn_wave(index: number)
	local arrivals = LAYOUT.arrivals
	local now = mission_time()
	-- each route is worked out anew for the wave, since the ground may have changed
	table.clear(routes)
	local by_side: { { string } } = {}
	for side in arrivals do
		by_side[side] = {}
	end
	for _, each in waves[index].units do
		for side in arrivals do
			local here = each.count // #arrivals + (if side <= each.count % #arrivals then 1 else 0)
			for _ = 1, here do
				table.insert(by_side[side], each.def_name)
			end
		end
	end
	for side, names in by_side do
		local gap = SPAWN_SECONDS * pace / math.max(#names, 1)
		for order, def_name in names do
			table.insert(to_come, { at = now + (order - 1) * gap, def_name = def_name, side = side })
		end
	end
	-- whatever the player left in the zone the wave arrived in is gone
	clear_zone()
	arrived = index
	local final = index == #waves
	for team_id_seen in state.all_teams() do
		if is_player_team(team_id_seen) then
			local middle = heightmap.ground_position(arrivals[1].X, 0)
			notifications.to_team(team_id_seen, {
				kind = if final then "final_wave" else "wave",
				amount = index,
				at = middle,
			})
		end
	end
end

-- Sends on whichever of the waves' units have stopped: at the player's nearest thing, fighting their way there.
local function direct()
	local now = mission_time()
	for _, unit in state.all() do
		if unit.alive == false or unit.team ~= enemy_team or unit.kind ~= "unit" or #unit.orders > 0 then
			continue
		end
		if (next_send[unit.id] or 0) > now then
			continue
		end
		local def = unit.def
		if unit_defs.is_air(def) then
			send_bomber(unit)
			next_send[unit.id] = now + DIRECT_SECONDS
			continue
		end
		local target = nearest_player_thing(unit.position, false)
		if target == nil then
			return
		end
		local chain = fight_route(def, unit.position, target.position)
		if chain == nil then
			return
		end
		orders.issue(unit, chain, false, false)
		next_send[unit.id] = now + RESEND_SECONDS
	end
end

-- Warns the player of each building of theirs newly going up in the enemy zone, once a team every WARN_GAP_SECONDS.
local function watch_zone()
	local now = mission_time()
	for _, entity in state.all() do
		if
			entity.alive == false
			or entity.kind ~= "building"
			or warned[entity.id] == true
			or is_player_team(entity.team) == false
			or is_in_zone(entity.position) == false
		then
			continue
		end
		warned[entity.id] = true
		local last = warned_at[entity.team]
		if last == nil or now - last >= WARN_GAP_SECONDS then
			warned_at[entity.team] = now
			notifications.to_team(entity.team, { kind = "enemy_zone", at = entity.position })
		end
	end
end

-- Forgets the mission, for it to begin again or another to. The usual timing is back (`retime`).
local function reset()
	began_at = nil
	prep_seconds = LAYOUT.prep_seconds
	pace = 1
	waves = mission_forces.COUNTERATTACK_WAVES
	arrived = 0
	enemy_team = nil
	direct_timer = 0
	zone_timer = 0
	table.clear(next_send)
	table.clear(warned)
	table.clear(warned_at)
	table.clear(furnished)
	table.clear(to_come)
	table.clear(routes)
end

-- The overlook's enemy, wrecked where it stood, and an enemy playing as `enemy` with nothing yet, for the waves to play
-- as, the hard mode's in its hard mode. The player's base goes down with their commander (`on_commander_down`).
local function setup(enemy: TeamId, playing: kit.Playing)
	reset()
	waves = if playing.hard then mission_forces.COUNTERATTACK_HARD_WAVES else mission_forces.COUNTERATTACK_WAVES
	enemy_team = enemy
	for _, center in kit.extractor_sites(overlook.is_below, kit.WEST) do
		kit.place_wreck(kit.EXTRACTOR_DEF, center, kit.WEST)
	end
	for _, each in mission_forces.OVERLOOK_ENEMY do
		local at = each.wrecked_at or overlook.enemy_at(each)
		kit.place_wreck(each.def_name, kit.standing_center(each.def_name, at.X, at.Y, kit.WEST), kit.WEST)
	end
end

-- Puts the player's base (BASE) down for `team_id`, whose commander has just gone down, and starts the mission's
-- clock. Anything there is no room for where it should be goes down as near as there is. Only the first team gets the
-- extractors and the buildings: there is one base, and a co-op player after the first brings only an army.
local function on_commander_down(team_id: TeamId)
	local first = next(furnished) == nil
	furnished[team_id] = true
	if first then
		local sites = kit.extractor_sites(function(spot: Vector3): boolean
			return overlook.is_below(spot) == false
		end, kit.EAST)
		kit.place_extractors(team_id, sites, kit.EAST)
	end
	local army: { kit.Placed } = {}
	for _, each in BASE do
		if first == false and unit_defs.get(each.def_name).kind == "building" then
			continue
		end
		local x = if each.back ~= nil then mission_map.brink_x(each.at.Y) - each.back else each.at.X
		table.insert(army, { def_name = each.def_name, at = Vector2.new(x, each.at.Y) })
	end
	kit.place_all(army, team_id, kit.EAST)
	if began_at == nil then
		began_at = state.now()
	end
end

-- Runs the mission on by `delta` seconds: whatever waves are due arrive, and the units already here are sent on.
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
	zone_timer += delta
	if zone_timer >= ZONE_CHECK_SECONDS then
		zone_timer = 0
		watch_zone()
	end
end

-- How many of the waves' units that have arrived are still to come down.
local function arriving(): number
	return #to_come
end

-- The enemy has nothing between its waves: it is only beaten once all of the last of them has come down.
local function is_beaten(): boolean
	return arrived >= #waves and arriving() == 0
end

-- Once a wave has been wiped out (the enemy has `enemy_left` things standing), the next comes CLEARED_SECONDS later if
-- it was due any later than that: the clock is put on, which brings every wave after it on as much. The time to
-- prepare is never cut short.
local function on_enemy_counted(enemy_left: number)
	if began_at == nil or enemy_left > 0 or #to_come > 0 or arrived == 0 or arrived >= #waves then
		return
	end
	local due = arrival_time(arrived + 1)
	if due - mission_time() > CLEARED_SECONDS then
		began_at = state.now() - (due - CLEARED_SECONDS)
	end
end

-- The zone, and how the waves stand: the whole seconds to the next, none once the last has arrived, and the whole time
-- to prepare until the clock has started.
local function hud(enemy_left: number): mission_state.Hud?
	if enemy_team == nil then
		return nil
	end
	return {
		zone_x = LAYOUT.zone_x,
		waves = {
			wave = arrived,
			waves = #waves,
			wave_in = if arrived < #waves
				then math.max(0, math.ceil(arrival_time(arrived + 1) - mission_time()))
				else nil,
			left = enemy_left,
		},
	}
end

-- `prep` seconds to prepare in place of the layout's, and the gaps between waves `wave_pace` times as long as they
-- say, either nil for the usual. It re-times the mission under way, prep and all, by the mission's time: a prep
-- shorter than has already gone brings the first wave at once. Setting the mission up again (`reset`) puts the usual
-- back.
local function retime(prep: number?, wave_pace: number?)
	prep_seconds = prep or LAYOUT.prep_seconds
	pace = wave_pace or 1
end

-- A unit that is gone need not be remembered.
local function forget(id: EntityId)
	next_send[id] = nil
	warned[id] = nil
end

local handler: kit.Handler = {
	setup = setup,
	reset = reset,
	tick = tick,
	on_commander_down = on_commander_down,
	is_beaten = is_beaten,
	arriving = arriving,
	on_enemy_counted = on_enemy_counted,
	end_mode = "commanders",
	hud = hud,
	retime = retime,
	forget = forget,
}

return table.freeze({
	handler = table.freeze(handler),
})
