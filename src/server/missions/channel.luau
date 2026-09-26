--!strict
-- Channel Crossing, the fifth mission, on the "channel" map (shared/map_designs/channel.luau): the player's commander on
-- the west shore, and across the channel, past an island it holds an outpost on, an enemy the AI plays, dug in behind
-- its line of floating defences and its guns on the shore, Agitators among them (mission_forces.CHANNEL_ENEMY). The AI builds nothing that crosses water (CROSSING, its roster):
-- no ships and no hovercraft, no aircraft, and nothing that wades; so it holds its shore and never comes over, and the
-- player has to go to it, by sea. The mission is won once the enemy's commander is dead, and lost once the player's is,
-- or once the time limit (mission_forces.CHANNEL_LAYOUT) has run out, which counts from the player's commander going
-- down: less time in the hard mode.
--
-- In the hard mode the enemy has more on the water and two more Agitators (CHANNEL_HARD_ENEMY), and bombers raid the
-- player every so often, which the mission sends in over the east edge (`raid`) at whatever the player has built nearest
-- them: the AI makes no aircraft of its own.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local mission_forces = require(ReplicatedStorage.Shared.mission_forces)

local state = require(ServerScriptService.Server.state)
local spawning = require(ServerScriptService.Server.spawning)
local orders = require(ServerScriptService.Server.orders)
local spatial = require(ServerScriptService.Server.spatial)
local ai = require(ServerScriptService.Server.ai)
local snapshot = require(ServerScriptService.Server.snapshot)

local kit = require(script.Parent.kit)

type Entity = types.Entity
type TeamId = types.TeamId
type Profile = ai_profiles.Profile

local LAYOUT = mission_forces.CHANNEL_LAYOUT

-- The enemy's metal spots are those east of this.
local ENEMY_SHORE_X = 150
-- The line under the result when the time runs out.
local TIME_UP = "Time ran out"
-- How often, in seconds of game, the raids' bombers are looked over for any that want sending on.
local DIRECT_SECONDS = 1

-- What the enemy's AI may build: the first tier of the bot line and its towers, none of which crosses water. The
-- Trasher is left out: it wades, as a commander does.
local CROSSING: { [string]: boolean } = {}
for _, name in
	{
		"bot_lab",
		"construction_bot",
		"grunt",
		"tick",
		"thug",
		"aggravator",
		"metal_extractor",
		"wind_turbine",
		"solar_collector",
		"energy_storage",
		"metal_storage",
		"energy_converter",
		"construction_turret",
		"guard",
		"twin_guard",
		"warden",
		"thistle",
	}
do
	CROSSING[name] = true
end
table.freeze(CROSSING)

-- The enemy's AI: the turtle's, which sits tight at home, keeping to the first tier of the bot line and to its own
-- shore.
local PROFILE: Profile = ai_profiles.with(ai_profiles.get "turtle" :: Profile, {
	name = "channel",
	roster = CROSSING,
	line = "bot",
	expansion_radius = 90,
})

local enemy_team: TeamId? = nil
-- Whether the enemy is still to be handed to the AI, which it is once the game has begun (`tick`).
local waiting = false
local hard = false
-- When, by the game's clock (state.now), the first of the players' commanders went down, or nil until one has; the time
-- limit counts from there (`mission_time`).
local began_at: number? = nil
-- How long the player has, and how much longer than the layout says the gaps between raids are; a Studio test or the
-- command bar changes both (`retime`).
local time_limit = LAYOUT.time_limit
local raid_pace = 1
-- How many raids have come.
local raids = 0
local direct_timer = 0

local function is_player_team(team_id: TeamId): boolean
	return kit.is_players(team_id, enemy_team)
end

-- Seconds since the player's commander went down; 0 until it has.
local function mission_time(): number
	return if began_at ~= nil then state.now() - began_at else 0
end

-- When raid `index` comes, by the mission's time.
local function raid_time(index: number): number
	return LAYOUT.first_raid + (index - 1) * LAYOUT.raid_gap * raid_pace
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

-- Raid `index` comes in: its bombers, half over each arrival, each sent at what the player has built nearest it.
local function raid(index: number)
	local count = math.min(LAYOUT.raid_most, LAYOUT.raid_bombers + (index - 1) // LAYOUT.raid_growth)
	local arrivals = LAYOUT.raid_arrivals
	for number = 1, count do
		local arrival = arrivals[(number - 1) % #arrivals + 1]
		local unit = spawning.spawn_near(
			"whirlwind",
			enemy_team :: TeamId,
			heightmap.ground_position(arrival.X, arrival.Y),
			kit.WEST
		)
		if unit ~= nil then
			-- the mission commands the raids, not the AI
			ai.leave_alone(unit.id)
			send_bomber(unit)
		end
	end
end

-- Sends on whichever of the raids' bombers have nothing to do.
local function direct()
	for _, unit in state.all() do
		if
			unit.alive
			and unit.team == enemy_team
			and unit.kind == "unit"
			and unit_defs.is_air(unit.def)
			and #unit.orders == 0
		then
			send_bomber(unit)
		end
	end
end

local function reset()
	enemy_team = nil
	waiting = false
	hard = false
	began_at = nil
	time_limit = LAYOUT.time_limit
	raid_pace = 1
	raids = 0
	direct_timer = 0
end

-- The enemy, playing as `enemy`: its commander at its start, an extractor on each of its metal spots, and its
-- defences and base, the hard mode's besides in its hard mode. The AI takes it over once the game has begun.
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
	waiting = true
end

-- The first of the players' commanders has gone down: the time limit starts.
local function on_commander_down(_team_id: TeamId)
	if began_at == nil then
		began_at = state.now()
	end
end

-- Hands the enemy to the AI once the game has begun, and brings the hard mode's raids as they come due.
local function tick(delta: number)
	local enemy = enemy_team
	if enemy == nil then
		return
	end
	if waiting then
		waiting = false
		ai.take_over(enemy, nil, PROFILE)
	end
	if hard == false or began_at == nil then
		return
	end
	while mission_time() >= raid_time(raids + 1) do
		raids += 1
		raid(raids)
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

-- `limit` seconds for the time limit in place of the layout's, and the gaps between raids `pace` times as long as it
-- says, either nil for the usual.
local function retime(limit: number?, pace: number?)
	time_limit = limit or (if hard then LAYOUT.hard_time_limit else LAYOUT.time_limit)
	raid_pace = pace or 1
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
		waiting = waiting,
		hard = hard,
		began_at = began_at,
		time_limit = time_limit,
		raid_pace = raid_pace,
		raids = raids,
		direct_timer = direct_timer,
	}
end, function(saved)
	enemy_team = saved.enemy_team
	waiting = saved.waiting
	hard = saved.hard
	began_at = saved.began_at
	time_limit = saved.time_limit
	raid_pace = saved.raid_pace
	raids = saved.raids
	direct_timer = saved.direct_timer
end)

return table.freeze({
	handler = table.freeze(handler),
	PROFILE = PROFILE,
	CROSSING = CROSSING,
})
