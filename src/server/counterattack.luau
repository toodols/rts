-- The third campaign mission, the counterattack (campaign.COUNTERATTACK, on the overlook's map), once it is under way:
-- the waves, the enemy zone, and what the waves do when they get here. missions.luau sets the mission up (the wrecks of
-- the second mission's base, the player's base as they won it) and starts this mission's clock (`start`) once the
-- player's base is down, which is once their commander is, when the game begins.
--
-- The player has `prep_seconds` to prepare. Then the waves come, one after another at the times WAVES gives, each
-- bigger than the last and the last of them the final wave: every unit of one goes down together at the east end of the
-- map, half at each of the layout's arrivals, and is sent fighting its way to the player's base, the north half by the
-- north ramp and the south half by the south. A unit that has got where it was sent, or has run out of the way there,
-- is sent on at whatever of the player's is nearest, and a bomber is sent at the player's building nearest it, again
-- whenever the one it was sent at is gone. Tanks cannot climb the ramps, which are made for bots: sent the same way,
-- they go as far as they can, to the foot of the cliff or of a ramp, and shell whatever is in reach from there.
--
-- The enemy zone is the strip of the map east of `zone_x`, where the waves arrive, all of every wave inside it and none
-- of the old base: whatever the player has there when a wave arrives is destroyed, and a building of theirs going up
-- there is warned of as they place it (a notification, server/notifications.luau). The mission is won once the final
-- wave has arrived and the enemy has nothing left (missions.luau asks `final_wave_arrived`), and lost as any other is.
--
-- What the HUD shows of it is published as the Workspace attributes campaign.COUNTERATTACK_ATTRIBUTES names.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local campaign = require(ReplicatedStorage.Shared.campaign)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

local state = require(script.Parent.state)
local spawning = require(script.Parent.spawning)
local orders = require(script.Parent.orders)
local combat = require(script.Parent.combat)
local notifications = require(script.Parent.notifications)

type Entity = types.Entity
type EntityId = types.EntityId
type TeamId = types.TeamId
type Order = types.Order

-- A wave: when it arrives, in seconds after the first does, and how many of each def it brings.
type Wave = {
	at: number,
	units: { [string]: number },
}

local LAYOUT = campaign.COUNTERATTACK
local ATTRIBUTES = campaign.COUNTERATTACK_ATTRIBUTES
-- The Workspace attributes a Studio test's timing (`set_timing`) is kept in: the seconds to prepare, and the pace.
local TIMING_ATTRIBUTES = table.freeze({
	prep = "CounterattackPrep",
	pace = "CounterattackPace",
})

-- Every wave, the last of them the final wave. They grow over some eight minutes, from a raid of grunts and incisors
-- (about 500 metal of units) to the final wave's 33 units (about 4,500), some 14,800 metal in all. Against that the
-- player has the thugs and aggravators they took the heights with (about 1,300), their four extractors and commander's
-- 10 metal a second (3,000 in the five minutes they have to prepare, and more as the waves come), the 1,000 they start
-- with, and the wrecks below. Above all the second mission's base's: its eight guards, raised by the two graverobbers
-- they start with (12.5 seconds and 700 energy a guard, and no metal) and repaired whole by them after (some 6 seconds
-- more), stand on the low ground across the waves' way to the ramps, where the thugs above can cover them; a guard
-- that falls leaves its wreck to be raised again between waves. Left to themselves they should hold to about the fifth
-- wave, and raised again, with the old base's storage and solars raised for the energy to fire, past the last; thugs
-- and aggravators alone should be overrun by the fourth. From the fourth wave wolverines come too, whose shells
-- outreach the guards, and from the fifth bombers, which only anti-air does much to.
local WAVES: { Wave } = {
	{ at = 0, units = { grunt = 6, incisor = 2 } },
	{ at = 80, units = { grunt = 6, thug = 3, incisor = 2 } },
	{ at = 160, units = { grunt = 4, thug = 4, aggravator = 2, incisor = 3 } },
	{ at = 240, units = { grunt = 4, thug = 3, aggravator = 2, brute = 1, incisor = 2, wolverine = 2 } },
	{
		at = 320,
		units = {
			grunt = 6,
			thug = 4,
			aggravator = 2,
			brute = 2,
			centurion = 1,
			incisor = 2,
			wolverine = 2,
			whirlwind = 1,
		},
	},
	{
		at = 400,
		units = {
			grunt = 6,
			thug = 4,
			aggravator = 3,
			brute = 3,
			centurion = 2,
			incisor = 2,
			wolverine = 3,
			whirlwind = 2,
		},
	},
	{
		at = 480,
		units = {
			grunt = 8,
			thug = 5,
			aggravator = 4,
			brute = 3,
			centurion = 3,
			incisor = 3,
			wolverine = 4,
			whirlwind = 3,
		},
	},
}
-- The order a wave's units are put down in, the heaviest first, so that they get the places nearest their arrival.
local SPAWN_ORDER = { "brute", "centurion", "wolverine", "thug", "aggravator", "incisor", "grunt", "whirlwind" }
-- They arrive facing west, at the player.
local WEST = -math.pi / 2

-- How often, in seconds of game, the waves' units are looked over for any that want sending on.
local DIRECT_SECONDS = 1
-- How many routes a look over may work out, each settling no more than PATH_MAX_EXPANSIONS cells; a unit left over is
-- sent the next time.
local PATHS_PER_PASS = 6
local PATH_MAX_EXPANSIONS = 6000
-- A unit sent on is not sent again for this long, however soon it stops: a tank at the foot of the cliff stops at once,
-- having gone as far as it can, and would otherwise have its route worked out anew every look.
local RESEND_SECONDS = 10
-- How often the enemy zone is looked over for new buildings of the player's, in seconds of game, and how long after a
-- team is warned it may be warned again, so that a line of buildings dragged out there is one warning.
local ZONE_CHECK_SECONDS = 0.5
local WARN_GAP_SECONDS = 5
-- Enough damage to destroy anything outright.
local DESTROY_DAMAGE = 1e9

-- The mission's clock: seconds since the player's base went down, or nil until it has.
local clock: number? = nil
-- How long the player has to prepare, and how much longer than WAVES say the gaps between waves are; a Studio test
-- shortens both (`set_timing`).
local prep_seconds = LAYOUT.prep_seconds
local pace = 1
-- How many waves have arrived.
local arrived = 0
local enemy_team: TeamId? = nil
local direct_timer = 0
local zone_timer = 0
-- When each of the waves' units may next be sent on, by the mission's clock.
local next_send: { [EntityId]: number } = {}
-- The player's buildings in the zone that have been warned of, and when each team was last warned.
local warned: { [EntityId]: boolean } = {}
local warned_at: { [TeamId]: number } = {}
-- The whole seconds to the next wave, as last published.
local published_wave_in: number? = nil

local function publish(name: string, value: any)
	if Workspace:GetAttribute(name) ~= value then
		Workspace:SetAttribute(name, value)
	end
end

-- Whether `team_id` is the player's (or a co-op player's): anybody's but the enemy's, nobody's and the scavengers'.
local function is_player_team(team_id: TeamId): boolean
	return team_id ~= enemy_team and team_id ~= 0 and team_id ~= config.SCAVENGER_TEAM
end

local function is_in_zone(position: Vector3): boolean
	return position.X >= LAYOUT.zone_x
end

-- When wave `index` arrives, by the mission's clock.
local function arrival_time(index: number): number
	return prep_seconds + WAVES[index].at * pace
end

-- The middle of the player's base, where a wave is sent.
local function base_position(): Vector3
	local start = campaign.OVERLOOK.player_start
	return heightmap.ground_position(start.X, start.Y)
end

-- The fight orders that take a unit of `def` from `from` to `to`, by the way round the cliff if it has to go round, or
-- as far as it can get when it cannot get there (a tank, which cannot climb the ramps).
local function fight_route(def: types.EntityDef, from: Vector3, to: Vector3): { Order }
	local chain: { Order } = {}
	local steps = pathfinder.route(def, from, to, PATH_MAX_EXPANSIONS)
	for _, step in steps do
		table.insert(chain, { kind = "fight", position = step.position })
	end
	return chain
end

-- The player's thing nearest `from`: of their buildings only, for `buildings_only`.
local function nearest_player_thing(from: Vector3, buildings_only: boolean): Entity?
	local best: Entity? = nil
	local best_distance = math.huge
	for _, entity in state.all() do
		if
			entity.alive == false
			or is_player_team(entity.team) == false
			or (entity.kind ~= "building" and (buildings_only or entity.kind ~= "unit"))
		then
			continue
		end
		local distance = geometry.distance_2d(from, entity.position)
		if distance < best_distance then
			best = entity
			best_distance = distance
		end
	end
	return best
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
			combat.apply_damage(entity, DESTROY_DAMAGE, nil, nil)
		end
	end
end

-- Puts wave `index` down at the arrivals and sends it at the player's base: the units of each def at an arrival are sent
-- by one route, worked out from there.
local function spawn_wave(index: number)
	local team_id = enemy_team :: TeamId
	local wave = WAVES[index]
	local goal = base_position()
	local arrivals = LAYOUT.arrivals
	-- the half of each def that goes to each arrival, the odd one to the first
	for _, def_name in SPAWN_ORDER do
		local count = wave.units[def_name] or 0
		if count == 0 then
			continue
		end
		local def = unit_defs.get(def_name)
		for side, arrival in arrivals do
			local here = count // #arrivals + (if side <= count % #arrivals then 1 else 0)
			if here == 0 then
				continue
			end
			local at = heightmap.ground_position(arrival.X, arrival.Y)
			local chain = if unit_defs.is_air(def) then nil else fight_route(def, at, goal)
			-- all of a wave comes down in the zone, clear of its edge
			local margin = unit_defs.collider_radius(def)
			local function in_zone(x: number, _z: number): boolean
				return x - margin >= LAYOUT.zone_x
			end
			for _ = 1, here do
				local unit = spawning.spawn_near(def_name, team_id, at, WEST, in_zone)
				if unit == nil then
					warn(`the counterattack found no room for its {def_name} at {arrival}`)
					continue
				end
				if chain ~= nil then
					orders.issue(unit, table.clone(chain), false, false)
				else
					send_bomber(unit)
				end
				next_send[unit.id] = (clock :: number) + RESEND_SECONDS
			end
		end
	end
	-- whatever the player left in the zone the wave arrived in is gone
	clear_zone()
	arrived = index
	publish(ATTRIBUTES.wave, arrived)
	local final = index == #WAVES
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
	local now = clock :: number
	local paths_left = PATHS_PER_PASS
	for _, unit in state.all() do
		if unit.alive == false or unit.team ~= enemy_team or unit.kind ~= "unit" or #unit.orders > 0 then
			continue
		end
		if (next_send[unit.id] or 0) > now then
			continue
		end
		local def = unit_defs.of(unit)
		if unit_defs.is_air(def) then
			send_bomber(unit)
			next_send[unit.id] = now + DIRECT_SECONDS
			continue
		end
		if paths_left <= 0 then
			return
		end
		local target = nearest_player_thing(unit.position, false)
		if target == nil then
			return
		end
		paths_left -= 1
		orders.issue(unit, fight_route(def, unit.position, target.position), false, false)
		next_send[unit.id] = now + RESEND_SECONDS
	end
end

-- Warns the player of each building of theirs newly going up in the enemy zone, once a team every WARN_GAP_SECONDS.
local function watch_zone()
	local now = clock or 0
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

-- Publishes the whole seconds to the next wave, none once the last has arrived: the whole time to prepare until the
-- clock has started.
local function publish_wave_in()
	local wave_in: number? = nil
	if enemy_team ~= nil and arrived < #WAVES then
		wave_in = math.max(0, math.ceil(arrival_time(arrived + 1) - (clock or 0)))
	end
	if wave_in ~= published_wave_in then
		published_wave_in = wave_in
		Workspace:SetAttribute(ATTRIBUTES.wave_in, wave_in)
	end
end

-- Forgets the mission, and clears what it published, for a new one. A Studio test's timing goes too (`set_timing`).
local function reset()
	clock = nil
	prep_seconds = LAYOUT.prep_seconds
	pace = 1
	arrived = 0
	enemy_team = nil
	direct_timer = 0
	zone_timer = 0
	table.clear(next_send)
	table.clear(warned)
	table.clear(warned_at)
	published_wave_in = nil
	for _, name in ATTRIBUTES do
		Workspace:SetAttribute(name, nil)
	end
	for _, name in TIMING_ATTRIBUTES do
		Workspace:SetAttribute(name, nil)
	end
end

-- The mission is being set up, with its enemy playing as `team_id`: the zone and the waves are published, and it waits
-- for the player's base to go down (`start`).
local function setup(team_id: TeamId)
	reset()
	enemy_team = team_id
	publish(ATTRIBUTES.zone_x, LAYOUT.zone_x)
	publish(ATTRIBUTES.waves, #WAVES)
	publish(ATTRIBUTES.wave, 0)
	publish_wave_in()
end

-- The player's base is down: the time to prepare begins.
local function start()
	if clock == nil then
		clock = 0
		publish_wave_in()
	end
end

-- Whether the mission's clock has started.
local function has_started(): boolean
	return clock ~= nil
end

-- Runs the mission on by `delta` seconds: whatever waves are due arrive, and the units already here are sent on.
local function tick(delta: number)
	if clock == nil or enemy_team == nil then
		return
	end
	clock += delta
	while arrived < #WAVES and (clock :: number) >= arrival_time(arrived + 1) do
		spawn_wave(arrived + 1)
	end
	publish_wave_in()
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

-- Whether the final wave has arrived, after which the enemy having nothing left wins the mission.
local function final_wave_arrived(): boolean
	return arrived >= #WAVES
end

-- How many of the enemy's things are left standing, as missions.luau counts them, for the HUD.
local function set_enemies_left(count: number)
	publish(ATTRIBUTES.enemies_left, count)
end

-- Takes up the timing the Workspace's dev attributes (TIMING_ATTRIBUTES) ask for, the usual where one is not set.
local function apply_timing()
	local prep = Workspace:GetAttribute(TIMING_ATTRIBUTES.prep)
	local wave_pace = Workspace:GetAttribute(TIMING_ATTRIBUTES.pace)
	prep_seconds = if typeof(prep) == "number" then prep else LAYOUT.prep_seconds
	pace = if typeof(wave_pace) == "number" then wave_pace else 1
	publish_wave_in()
end

-- For a Studio test, or from the command bar: `prep` seconds to prepare in place of the layout's, and the gaps between
-- waves `wave_pace` times as long as WAVES say. Either nil for the usual. It re-times the mission under way, prep and
-- all, by the mission's clock: a prep shorter than has already gone brings the first wave at once. Called once the
-- mission is set up, since setting it up again (`reset`) puts the usual back. The command bar requires a copy of this
-- module of its own, so the timing goes by way of Workspace attributes, which the copy the game runs takes up.
local function set_timing(prep: number?, wave_pace: number?)
	Workspace:SetAttribute(TIMING_ATTRIBUTES.prep, prep)
	Workspace:SetAttribute(TIMING_ATTRIBUTES.pace, wave_pace)
	apply_timing()
end

for _, name in TIMING_ATTRIBUTES do
	Workspace:GetAttributeChangedSignal(name):Connect(apply_timing)
end

-- Whether the player has been warned of the building `id` of theirs going up in the enemy zone.
local function was_warned(id: EntityId): boolean
	return warned[id] == true
end

-- A unit that is gone need not be remembered.
local function forget(id: EntityId)
	next_send[id] = nil
	warned[id] = nil
end

-- What each wave brings, by def name, for a Studio test to check against.
local function wave_units(index: number): { [string]: number }?
	local wave = WAVES[index]
	return if wave ~= nil then table.clone(wave.units) else nil
end

-- When wave `index` arrives, in seconds after the first does at the usual pace, for a Studio test.
local function wave_at(index: number): number?
	local wave = WAVES[index]
	return if wave ~= nil then wave.at else nil
end

return table.freeze({
	WAVE_COUNT = #WAVES,
	TIMING_ATTRIBUTES = TIMING_ATTRIBUTES,
	setup = setup,
	start = start,
	has_started = has_started,
	tick = tick,
	reset = reset,
	final_wave_arrived = final_wave_arrived,
	set_enemies_left = set_enemies_left,
	set_timing = set_timing,
	forget = forget,
	wave_units = wave_units,
	wave_at = wave_at,
	was_warned = was_warned,
	is_in_zone = is_in_zone,
})
