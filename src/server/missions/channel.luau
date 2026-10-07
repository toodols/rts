--!strict
-- Channel Crossing, the fifth mission, on the "channel" map (shared/map_designs/channel.luau): the player's commander
-- on the west shore, and across the channel the enemy's, its Agitators on the island and on its own shore holding the
-- water (mission_forces.CHANNEL_ENEMY). Nobody plays the enemy: it builds nothing and never comes over, and its
-- defences and commander fight whatever comes near them. The player sinks the Agitators with ships and lands Garpikes.
-- The mission is won once the enemy's commander is dead, and lost once the player's is, or once the time limit
-- (mission_forces.CHANNEL_LAYOUT) has run out, which counts from the player's commander going down: less time in the
-- hard mode.
--
-- In the hard mode the enemy has two more Corals and an Air Lab besides (CHANNEL_HARD_ENEMY). The mission keeps the lab
-- making Whirlwinds, from a while in (CHANNEL_LAYOUT.air_lab_delay), and sends them in raids at whatever the player has
-- built nearest them, once enough wait by the lab.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local mission_forces = require(ReplicatedStorage.Shared.mission_forces)

local state = require(ServerScriptService.Server.state)
local spawning = require(ServerScriptService.Server.spawning)
local orders = require(ServerScriptService.Server.orders)
local spatial = require(ServerScriptService.Server.spatial)
local production = require(ServerScriptService.Server.production)
local snapshot = require(ServerScriptService.Server.snapshot)

local kit = require(script.Parent.kit)

type Entity = types.Entity
type TeamId = types.TeamId

local LAYOUT = mission_forces.CHANNEL_LAYOUT

-- The enemy's metal spots are those east of this.
local ENEMY_SHORE_X = 150
-- The line under the result when the time runs out.
local TIME_UP = "Time ran out"
-- How often, in seconds of game, the Air Lab and its bombers are looked over.
local DIRECT_SECONDS = 1
-- What the Air Lab makes.
local BOMBER = "whirlwind"
-- How near an Air Lab an idle bomber waits for the rest of its raid; one idle anywhere else has been on a raid, and is
-- sent on again at once.
local WAITING_RADIUS = 40

local enemy_team: TeamId? = nil
local hard = false
-- When, by the game's clock (state.now), the first of the players' commanders went down, or nil until one has; the time
-- limit counts from there (`mission_time`).
local began_at: number? = nil
-- How long the player has; a Studio test or the command bar changes it (`retime`).
local time_limit = LAYOUT.time_limit
-- How many raids have been sent.
local raids = 0
local direct_timer = 0

local function is_player_team(team_id: TeamId): boolean
	return kit.is_players(team_id, enemy_team)
end

-- Seconds since the player's commander went down; 0 until it has.
local function mission_time(): number
	return if began_at ~= nil then state.now() - began_at else 0
end

-- How many bombers the next raid waits for.
local function raid_size(): number
	return math.min(LAYOUT.raid_most, LAYOUT.raid_bombers + raids // LAYOUT.raid_growth)
end

-- The player's building nearest `from`, or failing any their nearest anything.
local function raid_target(from: Vector3): Entity?
	local function players(buildings_only: boolean): Entity?
		return spatial.nearest(from, math.huge, function(entity: Entity): boolean
			return is_player_team(entity.team)
				and (entity.kind == "building" or (buildings_only == false and entity.kind == "unit"))
		end)
	end
	return players(true) or players(false)
end

local function send_bomber(unit: Entity)
	local target = raid_target(unit.position)
	if target ~= nil then
		orders.issue(unit, { { kind = "attack", target_id = target.id } }, false, false)
	end
end

-- Keeps each of the enemy's Air Labs making bombers, and sends them: those waiting by a lab once there are enough for a
-- raid, and any other with nothing to do at once.
local function direct()
	local labs: { Entity } = {}
	for _, entity in state.all() do
		if entity.alive and entity.team == enemy_team and entity.def_name == "air_lab" and entity.state == "active" then
			table.insert(labs, entity)
			if #entity.queue == 0 and mission_time() >= LAYOUT.air_lab_delay then
				production.enqueue(entity, BOMBER)
			end
		end
	end
	local waiting: { Entity } = {}
	for _, unit in state.all() do
		if
			unit.alive == false
			or unit.team ~= enemy_team
			or unit.kind ~= "unit"
			or unit.state ~= "active"
			or unit_defs.is_air(unit.def) == false
			or #unit.orders > 0
		then
			continue
		end
		local by_a_lab = false
		for _, lab in labs do
			if geometry.distance_2d(unit.position, lab.position) <= WAITING_RADIUS then
				by_a_lab = true
				break
			end
		end
		if by_a_lab then
			table.insert(waiting, unit)
		else
			send_bomber(unit)
		end
	end
	if #waiting > 0 and #waiting >= raid_size() then
		raids += 1
		for _, unit in waiting do
			send_bomber(unit)
		end
	end
end

local function reset()
	enemy_team = nil
	hard = false
	began_at = nil
	time_limit = LAYOUT.time_limit
	raids = 0
	direct_timer = 0
end

-- The enemy, playing as `enemy`: its commander at its start, an extractor on each of its metal spots ashore, and its
-- defences, the hard mode's besides in its hard mode.
local function setup(enemy: TeamId, playing: kit.Playing)
	reset()
	enemy_team = enemy
	hard = playing.hard
	time_limit = if hard then LAYOUT.hard_time_limit else LAYOUT.time_limit
	local start = mission_map.here(mission_map.ENEMY_START)
	spawning.set_start(enemy, start)
	if spawning.give_starting_force(enemy) == false then
		warn "Channel Crossing found no room for the enemy's commander"
	end
	-- first, so that nothing else takes their spots
	kit.place_extractors(
		enemy,
		kit.extractor_sites(function(spot: Vector3): boolean
			return spot.X > ENEMY_SHORE_X
		end, kit.WEST),
		kit.WEST
	)
	local placed: { kit.Placed } = {}
	for _, each in mission_forces.CHANNEL_ENEMY do
		table.insert(placed, { def_name = each.def_name, at = each.at })
	end
	if hard then
		for _, each in mission_forces.CHANNEL_HARD_ENEMY do
			table.insert(placed, { def_name = each.def_name, at = each.at })
		end
	end
	kit.place_all(placed, enemy, kit.WEST)
end

-- The first of the players' commanders has gone down: the time limit starts.
local function on_commander_down(_team_id: TeamId)
	if began_at == nil then
		began_at = state.now()
	end
end

-- Runs the hard mode's Air Lab and raids, once the player's commander is down.
local function tick(delta: number)
	if enemy_team == nil or hard == false or began_at == nil then
		return
	end
	direct_timer += delta
	if direct_timer >= DIRECT_SECONDS then
		direct_timer = 0
		direct()
	end
end

-- Lost once the time has run out.
local function lost(): string?
	if began_at ~= nil and mission_time() >= time_limit then
		return TIME_UP
	end
	return nil
end

local function hud(_enemy_left: number): mission_state.Hud?
	if enemy_team == nil then
		return nil
	end
	return { time_left = math.max(0, math.ceil(time_limit - mission_time())) }
end

-- `limit` seconds for the time limit in place of the layout's, nil for the usual.
local function retime(limit: number?, _pace: number?)
	time_limit = limit or (if hard then LAYOUT.hard_time_limit else LAYOUT.time_limit)
end

local handler: kit.Handler = {
	setup = setup,
	reset = reset,
	tick = tick,
	on_commander_down = on_commander_down,
	lost = lost,
	end_mode = "commanders",
	enemy_end_mode = "commanders",
	hud = hud,
	retime = retime,
}

snapshot.keep("mission_channel", function()
	return {
		enemy_team = enemy_team,
		hard = hard,
		began_at = began_at,
		time_limit = time_limit,
		raids = raids,
		direct_timer = direct_timer,
	}
end, function(saved)
	enemy_team = saved.enemy_team
	hard = saved.hard
	began_at = saved.began_at
	time_limit = saved.time_limit
	raids = saved.raids
	direct_timer = saved.direct_timer
end)

return table.freeze({
	handler = table.freeze(handler),
})
