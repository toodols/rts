--!strict
-- Tests of the campaign's missions (server/missions): the tutorial's boulder and end, the overlook, the counterattack
-- and its balance, Prairie Skirmish, the hard modes, loading one mission over another, and the vote on going on to the
-- next.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local geometry = require(ReplicatedStorage.Shared.geometry)
local spots = require(ReplicatedStorage.Shared.spots)
local map_state = require(ReplicatedStorage.Shared.map_state)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local campaign = require(ReplicatedStorage.Shared.campaign)
local campaign_progress = require(ReplicatedStorage.Shared.campaign_progress)
local mission_map = require(ReplicatedStorage.Shared.mission_map)
local mission_state = require(ReplicatedStorage.Shared.mission_state)
local mission_forces = require(ReplicatedStorage.Shared.mission_forces)
local starts = require(ReplicatedStorage.Shared.starts)

local state = require(ServerScriptService.Server.state)
local damage = require(ServerScriptService.Server.damage)
local deaths = require(ServerScriptService.Server.deaths)
local orders = require(ServerScriptService.Server.orders)
local targeting = require(ServerScriptService.Server.targeting)
local maps = require(ServerScriptService.Server.maps)
local scenery = require(ServerScriptService.Server.scenery)
local missions = require(ServerScriptService.Server.missions)
local notifications = require(ServerScriptService.Server.notifications)
local reclaim = require(ServerScriptService.Server.reclaim)
local placement = require(ServerScriptService.Server.placement)
local spawning = require(ServerScriptService.Server.spawning)
local campaign_exit = require(ServerScriptService.Server.campaign_exit)
local ai = require(ServerScriptService.Server.ai)
local players = require(ServerScriptService.Server.players)
local build_rules = require(ServerScriptService.Server.build_rules)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local NOCOST = harness.NOCOST
local advance = harness.advance
local now = harness.now
local round = harness.round
local spawn = harness.spawn
local ensure_team = harness.ensure_team
local until_idle = harness.until_idle
local with_switch = harness.with_switch
local shots_of = harness.shots_of

type Entity = types.Entity
type TeamId = types.TeamId
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- The counterattack's balance, at the usual pace: with all the old guards raised, something of the player's defence
-- (a guard, thug or aggravator) should still stand as wave BALANCE_HOLD_WAVE arrives, with no more than
-- BALANCE_MAX_LEFTOVER of the waves before it still about; with none raised, every thug and aggravator should be gone by
-- the time wave BALANCE_OVERRUN_WAVE arrives, or the game be lost.
local BALANCE_HOLD_WAVE = 5
local BALANCE_MAX_LEFTOVER = 8
local BALANCE_OVERRUN_WAVE = 4
-- Everything the counterattack's waves bring between them.
local COUNTERATTACK_DEFS = { "brute", "incisor", "grunt", "thug", "aggravator", "centurion", "wolverine", "whirlwind" }
-- The metal income the overlook's guide asks for (client/missions/overlook.luau).
local OVERLOOK_METAL_GOAL = 10

-- How many guards the old base has, whose wrecks the counterattack leaves (server/missions/overlook.luau).
local OLD_GUARDS = 0
for _, thing in mission_forces.OVERLOOK_ENEMY do
	if thing.def_name == "guard" then
		OLD_GUARDS += 1
	end
end

-- Kills everything of `team`'s outright, as a blow far past anything's health, leaving wrecks. Returns how many.
local function destroy_all(team: TeamId): number
	local killed = 0
	for _, entity in state.all() do
		if entity.alive and entity.team == team and (entity.kind == "unit" or entity.kind == "building") then
			damage.apply(entity, 1e9, nil)
			killed += 1
		end
	end
	return killed
end

-- Re-times the mission being played, as the command bar's mission_timing does.
local function retime(prep: number?, pace: number?)
	assert(missions.retime(prep, pace))
end

-- What the HUD would show of the counterattack's waves now: what is published with the rest of what the players are
-- sent, published at once.
local function hud_waves(): mission_state.Waves?
	missions.publish()
	return mission_state.waves()
end

-- The wave the HUD would show as the last to have arrived, 0 before any has.
local function hud_wave(): number
	local waves = hud_waves()
	return if waves ~= nil then waves.wave else 0
end

-- What each def wave `index` brings.
local function wave_units(index: number): { [string]: number }
	local units: { [string]: number } = {}
	local wave = mission_forces.COUNTERATTACK_WAVES[index]
	if wave ~= nil then
		for _, each in wave.units do
			units[each.def_name] = (units[each.def_name] or 0) + each.count
		end
	end
	return units
end

-- Whether `position` is below the cliff of the map being played.
local function below_cliff(position: Vector3): boolean
	return position.X >= mission_map.brink_x(position.Z)
end

-- The map's wall, the tutorial's boulder, if it stands: the one building that is nobody's.
local function find_boulder(): Entity?
	for _, entity in state.all() do
		if entity.alive and entity.team == harness.NEUTRAL and entity.kind == "building" then
			return entity
		end
	end
	return nil
end

-- Builds mission `mission_id`'s map afresh and sets it up, as a Studio run of it would, unless a match handed in has
-- set a mission up already. Returns the mission's enemy team.
local function set_up_mission(mission_id: string): TeamId
	if mission_state.enemy_team() == nil then
		local loaded, err = maps.load({ mission = mission_id, seed = game_modes.DEFAULT_SEED })
		assert(loaded, err)
		scenery.clear()
	end
	return mission_state.enemy_team() :: TeamId
end

-- Loads the counterattack as the mission_load command would (maps.load with a mission) and puts the player's commander
-- down as a player's arriving would, which puts their base down beside it. Returns the mission's enemy team.
local function start_counterattack(): TeamId
	local loaded, err = maps.load({ mission = "counterattack" })
	assert(loaded, err)
	ensure_team(OWN)
	local start = mission_map.here(mission_map.PLAYER_START)
	local commander = spawning.spawn_near("commander", OWN, heightmap.ground_position(start.X, start.Y), math.pi / 2)
	assert(commander ~= nil, "no room for the commander")
	advance(1)
	return mission_state.enemy_team() :: TeamId
end

-- The counterattack's waves coming sooner once one is wiped out (server/missions/counterattack.luau, CLEARED_SECONDS):
-- loaded as overlook_defense loads it, with `args.prep` (3) seconds to prepare and the gaps between waves three times as
-- long (30 seconds, so that some of one is left once a wave has come down), the first wave is waited for until all of
-- it has come down (missions.arriving), then destroyed outright. The time to the next should be more than 5 before
-- (`wave_in_before`, about 12), and no more than 5 a moment after (`wave_in_after`); the second wave should then arrive
-- within 6 seconds (`second_after`).
local function wave_cleared(args: Args): Findings
	local enemy = start_counterattack()
	retime(args.prep or 3, 3)
	local waited = 0
	while (hud_wave() < 1 or missions.arriving() > 0) and waited < 60 do
		advance(0.5)
		waited += 0.5
	end
	advance(1)
	local before = hud_waves()
	local wave_in_before = if before ~= nil then before.wave_in else nil
	local destroyed = destroy_all(enemy)
	advance(1)
	local after = hud_waves()
	local wave_in_after = if after ~= nil then after.wave_in else nil
	local second_after: number? = nil
	local since = 0
	while since < 10 do
		advance(0.25)
		since += 0.25
		if hud_wave() >= 2 then
			second_after = since + 1
			break
		end
	end
	return {
		first_arrived_after = waited,
		destroyed = destroyed,
		wave_in_before = wave_in_before,
		wave_in_after = wave_in_after,
		second_after = second_after,
		pass = destroyed > 0
			and wave_in_before ~= nil
			and wave_in_before > 5
			and wave_in_after ~= nil
			and wave_in_after <= 5
			and second_after ~= nil
			and second_after <= 6,
	}
end

-- The old base's guard wrecks in the counterattack, those nearest the cliff first.
local function old_guard_wrecks(): { Entity }
	local wrecks: { Entity } = {}
	for _, entity in state.all() do
		if
			entity.alive
			and entity.kind == "wreck"
			and entity.wreck ~= nil
			and entity.wreck.source_def_name == "guard"
			and below_cliff(entity.position)
		then
			table.insert(wrecks, entity)
		end
	end
	table.sort(wrecks, function(a: Entity, b: Entity): boolean
		return a.position.X < b.position.X
	end)
	return wrecks
end

-- The tutorial's boulder (server/missions/tutorial.luau, obstacles.luau, its def's damage_immunity), on the tutorial set
-- up afresh, its enemy standing far off on the other side. First, what does nothing to it: a grunt's shots at it for
-- `args.seconds` (6),
-- a commander's death blast beside it, a huge blow dealt it straight, and whether it can be reclaimed. Then a grunt told
-- to walk through the pass to the far side, which should get no further than the boulder's face in 12 seconds. Then a
-- commander disintegrating it, which should take one shot. Then the grunt told again, which should now get through.
local function tutorial_boulder(args: Args): Findings
	set_up_mission "tutorial"
	ensure_team(OWN)
	local layout = { chokepoint = mission_map.here "pass" }
	local boulder = find_boulder() :: Entity
	local full = boulder.health
	-- the boulder's face toward the player: it is turned so that its shorter side runs along the pass
	local half = unit_defs.footprint_half_extents(unit_defs.get(boulder.def_name))
	local face_x = layout.chokepoint.X - math.min(half.X, half.Y)
	local west = layout.chokepoint.X - 44
	local east = layout.chokepoint.X + 44
	local under = heightmap.ground_position(layout.chokepoint.X, layout.chokepoint.Y)

	-- what should do nothing: a commander going up beside it, off to one side so that it takes nothing else with it,
	-- a blow far past its health, a builder, and a grunt shooting at it
	local blast = spawn("commander", harness.ENEMY, layout.chokepoint.X - 10, layout.chokepoint.Y + 30)
	advance(tick_rate.TICK_DELTA)
	damage.apply(blast, 1e9, nil)
	advance(tick_rate.TICK_DELTA)
	local after_blast = boulder.health
	damage.apply(boulder, 1e9, nil)
	local after_blow = boulder.health
	local builder = spawn("construction_bot", OWN, west, layout.chokepoint.Y - 12)
	advance(tick_rate.TICK_DELTA)
	local reclaimable = reclaim.can_reclaim(builder, boulder)
	deaths.destroy(builder, "removed")
	local grunt = spawn("grunt", OWN, west, layout.chokepoint.Y)
	advance(tick_rate.TICK_DELTA)
	orders.issue(grunt, { { kind = "attack_ground", position = boulder.position, target_id = nil } }, false, false)
	advance(args.seconds or 6)
	local grunt_shots = shots_of(grunt.id, 1)
	local after_shots = boulder.health

	-- walking through while it stands
	local grunt_def = unit_defs.get "grunt"
	local function walk_east(seconds: number): number
		local route = pathfinder.route(grunt_def, grunt.position, heightmap.ground_position(east, layout.chokepoint.Y))
		orders.issue(grunt, route, false, false)
		local furthest = grunt.position.X
		advance(seconds, function()
			furthest = math.max(furthest, grunt.position.X)
		end)
		return furthest
	end
	local blocked_reach = walk_east(12)
	orders.issue(
		grunt,
		{ { kind = "move", position = heightmap.ground_position(west, layout.chokepoint.Y - 8), target_id = nil } },
		false,
		false
	)
	advance(4)

	-- disintegrating it, which costs nothing here, since what it costs is beside the point
	local commander = spawn("commander", OWN, west - 6, layout.chokepoint.Y)
	advance(tick_rate.TICK_DELTA)
	local healths = {}
	local shots = 0
	with_switch(NOCOST, true, function()
		while boulder.alive and shots < 6 do
			orders.issue(commander, { { kind = "dgun", position = under, target_id = nil } }, false, false)
			until_idle(commander, 15)
			shots += 1
			table.insert(healths, math.max(0, boulder.health))
		end
	end)
	advance(tick_rate.TICK_DELTA)
	local destroyed = boulder.alive == false and state.get(boulder.id) == nil
	local wrecks = 0
	for _, entity in state.all() do
		if entity.kind == "wreck" and entity.def_name == boulder.def_name then
			wrecks += 1
		end
	end
	local away = heightmap.ground_position(west - 20, layout.chokepoint.Y + 30)
	orders.issue(commander, { { kind = "move", position = away, target_id = nil } }, false, false)

	-- walking through once it is gone
	local open_reach = walk_east(15)

	return {
		boulder_health = full,
		grunt_shots = grunt_shots,
		health_after_shots = after_shots,
		health_after_blast = after_blast,
		health_after_blow = after_blow,
		reclaimable = reclaimable,
		face_x = face_x,
		blocked_reach = round(blocked_reach, 1),
		dgun_healths = healths,
		dgun_shots = shots,
		destroyed = destroyed,
		wrecks = wrecks,
		open_reach = round(open_reach, 1),
		pass = grunt_shots > 0
			and after_shots == full
			and after_blast == full
			and after_blow == full
			and reclaimable == false
			and blocked_reach < face_x + world_scale.CELL_STUDS
			and destroyed
			and shots == 1
			and wrecks == 0
			and open_reach > east - 8,
	}
end

-- The tutorial's end (server/missions): the mission set up as a lobby's match would have it (hand one in with
-- `match = { mode = "campaign_tutorial", ... }`), or else here, on the tutorial map. After a second the game should not
-- have ended; the enemy should have 3 extractors, each on a metal spot. Then everything of the enemy's is killed
-- outright, leaving wrecks, and a second later the game should have ended, won by everyone but the enemy, with the enemy
-- destroyed.
local function tutorial_victory(_args: Args): Findings
	local enemy = set_up_mission "tutorial"
	advance(1)
	local phase_before = game_phase.phase()
	local extractors, on_spots = 0, 0
	for _, entity in state.all() do
		if entity.team == enemy and entity.alive and entity.def_name == "metal_extractor" then
			extractors += 1
			if spots.multiplier_at(entity.position) ~= 1 then
				on_spots += 1
			end
		end
	end
	local killed = destroy_all(enemy)
	advance(1)
	local winners = game_phase.winners()
	return {
		enemy_team = enemy,
		extractors = extractors,
		extractors_on_spots = on_spots,
		killed = killed,
		phase_before = phase_before,
		phase = game_phase.phase(),
		winners = winners,
		reason = game_phase.end_reason(),
		result = missions.result(),
		pass = phase_before ~= "ended"
			and extractors == 3
			and on_spots == 3
			and game_phase.phase() == "ended"
			and missions.result() == "won"
			and table.find(winners, enemy) == nil,
	}
end

-- The overlook (server/missions/overlook.luau, on the "overlook" map), set up as a lobby's match would have it (hand one in with
-- `match = { mode = "campaign_overlook", ... }`), or else here. First the ground: the plateau under the player's start
-- and the low ground under the enemy's (`drop` should be about 28), how far the cliff's edge wanders (`edge_xs`), and a
-- grunt's route from one start to the other, which should be found (by a ramp or the road, not down the cliff), and a
-- tank's from the low ground up to the player's start, which only the road down the face makes (`tank_up`). Then the
-- player's side as the guide has it: an extractor put on each metal spot of theirs
-- (`spots`, each of which should take one and be reached by a grunt from the start), and with their commander, the
-- metal income the resource bar would show a few seconds on (`metal_income`), which should read the guide's goal (10).
-- Then the enemy: 15 things in all, 2 extractors on their spots, and full storage a second in. Then what can be
-- reached from the cliff: for each of the enemy's things, a thug put at the edge in line with it, and whether it could
-- shoot it from there (`in_reach`, about half) and whether the thing could shoot back (`fire_back`, none). Then what
-- the mission is about, each told to attack as a player would: a thug at the edge against the front guard nearest
-- z = 0, which it should kill without being hit; and, once what is in reach of the edge is gone, as the guide means it
-- to be by then, an aggravator come down the south ramp against the guard covering its foot, from `args.gap` (42)
-- studs short of it, at the foot, which it should hold at and kill without being hit, since its rockets outreach a
-- guard on the level. Each gets `args.seconds` (45).
local function overlook(args: Args): Findings
	local enemy = set_up_mission "overlook"
	ensure_team(OWN)
	local layout = {
		player_start = mission_map.here(mission_map.PLAYER_START),
		enemy_start = mission_map.here(mission_map.ENEMY_START),
	}
	local seconds = args.seconds or 45

	-- the ground
	local top = heightmap.height_at(layout.player_start.X, layout.player_start.Y)
	local bottom = heightmap.height_at(layout.enemy_start.X, layout.enemy_start.Y)
	local edge_xs: { number } = {}
	for z = -30, 30, 10 do
		table.insert(edge_xs, round(mission_map.brink_x(z), 1))
	end
	local route, found = pathfinder.route(
		unit_defs.get "grunt",
		heightmap.ground_position(layout.player_start.X, layout.player_start.Y),
		heightmap.ground_position(layout.enemy_start.X, layout.enemy_start.Y)
	)
	local widest_z = 0
	for _, order in route do
		if order.position ~= nil then
			widest_z = math.max(widest_z, math.abs(order.position.Z))
		end
	end

	-- and a tank's way up from the low ground, which is the road down the face: it should get to the plateau
	local tank_route, tank_found = pathfinder.route(
		unit_defs.get "incisor",
		heightmap.ground_position(layout.enemy_start.X, layout.enemy_start.Y),
		heightmap.ground_position(layout.player_start.X, layout.player_start.Y)
	)
	local tank_end = tank_route[#tank_route].position
	local tank_up = tank_found
		and tank_end ~= nil
		and geometry.distance_2d(tank_end, heightmap.ground_position(layout.player_start.X, layout.player_start.Y))
			<= 4

	-- the player's side: an extractor on each of their spots, and their commander, and what that makes
	local spot_rows: { string } = {}
	local spots_ok = 0
	local player_spots = 0
	for _, spot in spots.all "metal" do
		if below_cliff(spot.position) then
			continue
		end
		player_spots += 1
		-- a route always ends somewhere; it reaches the spot if it ends on it
		local way = pathfinder.route(
			unit_defs.get "grunt",
			heightmap.ground_position(layout.player_start.X, layout.player_start.Y),
			spot.position
		)
		local last = way[#way].position
		local reached = last ~= nil and geometry.distance_2d(last, spot.position) <= 4
		local center = placement.resolve_center("metal_extractor", spot.position.X, spot.position.Z, 0, nil)
		local placed = center ~= nil and placement.can_place("metal_extractor", center, 0, nil)
		if placed and reached then
			spots_ok += 1
			state.create_entity("metal_extractor", OWN, center :: Vector3, 0, "active")
		end
		table.insert(spot_rows, `{math.round(spot.position.X)},{math.round(spot.position.Z)}:{placed}/{reached}`)
	end
	local commander = spawn("commander", OWN, layout.player_start.X, layout.player_start.Y)
	advance(8)
	local metal_income = round((state.get_team(OWN) :: types.Team).metal_revenue, 2)
	deaths.destroy(commander, "removed")

	-- the enemy
	advance(1)
	local counts: { [string]: number } = {}
	local total = 0
	local extractors_on_spots = 0
	local things: { Entity } = {}
	for _, entity in state.all() do
		if entity.team ~= enemy or (entity.kind ~= "unit" and entity.kind ~= "building") then
			continue
		end
		total += 1
		counts[entity.def_name] = (counts[entity.def_name] or 0) + 1
		if entity.def_name == "metal_extractor" and spots.multiplier_at(entity.position) ~= 1 then
			extractors_on_spots += 1
		end
		table.insert(things, entity)
	end
	local team = state.get_team(enemy) :: types.Team
	local stored = round(team.energy, 0)
	local capacity = team.energy_capacity

	-- what a thug at the edge reaches
	local reachable: { Entity } = {}
	local in_reach: { string } = {}
	local fire_back: { string } = {}
	for _, thing in things do
		local z = thing.position.Z
		local thug = spawn("thug", OWN, mission_map.brink_x(z) - 1, z)
		advance(tick_rate.TICK_DELTA)
		local label = `{thing.def_name}@{math.round(thing.position.X)},{math.round(z)}`
		if targeting.can_shoot(thug, thing) then
			table.insert(in_reach, label)
			table.insert(reachable, thing)
		end
		if targeting.can_shoot(thing, thug) then
			table.insert(fire_back, label)
		end
		deaths.destroy(thug, "removed")
		advance(tick_rate.TICK_DELTA)
	end

	local function nearest(def_name: string, x: number, z: number): Entity
		local best, best_distance = things[1], math.huge
		for _, thing in things do
			local distance = geometry.distance_2d(thing.position, Vector3.new(x, 0, z))
			if thing.def_name == def_name and distance < best_distance then
				best, best_distance = thing, distance
			end
		end
		return best
	end

	-- `def_name` of the player's at (x, z), told to attack `guard`, for `seconds`
	local function duel(def_name: string, x: number, z: number, guard: Entity): Findings
		local attacker = spawn(def_name, OWN, x, z)
		advance(tick_rate.TICK_DELTA)
		local start = attacker.position
		local full = attacker.health
		orders.issue(attacker, { { kind = "attack", position = nil, target_id = guard.id } }, false, false)
		local killed_at: number? = nil
		local elapsed = 0
		advance(seconds, function()
			elapsed += tick_rate.TICK_DELTA
			if killed_at == nil and guard.alive == false then
				killed_at = elapsed
			end
		end)
		return {
			guard_dead = guard.alive == false,
			killed_after = if killed_at ~= nil then round(killed_at, 1) else nil,
			damage_taken = round(full - attacker.health, 0),
			moved = round(geometry.distance_2d(start, attacker.position), 1),
			distance = round(geometry.distance_2d(attacker.position, guard.position), 1),
			height_above = round(attacker.position.Y - guard.position.Y, 1),
			alive = attacker.alive,
		}
	end

	local front = nearest("guard", 15, 0)
	local thug = duel("thug", mission_map.brink_x(front.position.Z) - 1, front.position.Z, front)
	local ramp_guard = nearest("guard", 62, -42)
	for _, thing in reachable do
		if thing.alive then
			deaths.destroy(thing, "removed")
		end
	end
	advance(tick_rate.TICK_DELTA)
	local gap = args.gap or 42
	local aggravator = duel("aggravator", ramp_guard.position.X - gap, ramp_guard.position.Z, ramp_guard)

	return {
		plateau = round(top, 1),
		low_ground = round(bottom, 1),
		drop = round(top - bottom, 1),
		edge_xs = edge_xs,
		route_found = found,
		route_waypoints = #route,
		route_widest_z = round(widest_z, 1),
		tank_up = tank_up,
		tank_waypoints = #tank_route,
		spots = spot_rows,
		metal_income = metal_income,
		total = total,
		counts = counts,
		extractors_on_spots = extractors_on_spots,
		energy_stored = stored,
		energy_capacity = capacity,
		in_reach_count = #in_reach,
		in_reach = in_reach,
		fire_back = fire_back,
		thug = thug,
		aggravator = aggravator,
		pass = top - bottom > 24
			and found
			and tank_up
			and player_spots == 4
			and spots_ok == player_spots
			and math.floor(metal_income + 0.5) == OVERLOOK_METAL_GOAL
			and total == 15
			and extractors_on_spots == 2
			and stored == capacity
			and #in_reach >= 5
			and #in_reach <= 8
			and #fire_back == 0
			and thug.guard_dead
			and thug.damage_taken == 0
			and aggravator.guard_dead
			and aggravator.damage_taken == 0,
	}
end

-- The counterattack (server/missions/counterattack.luau, on the overlook's map), loaded as the mission_load command
-- would, with `args.prep` seconds to prepare (5) and the gaps between its waves `args.pace` times as long as they are
-- (0.3), and the player's commander put down as a player's arriving would. First the setup, once the commander's base
-- has gone down beside it: the player's things by def (`own`: the commander, 4 extractors all on metal spots, 6 solar
-- collectors, a bot lab, 2 graverobbers, 6 thugs and 4 aggravators), the wrecks of the overlook's enemy east of the
-- cliff (`wrecks`: 8 guards, 4 solar collectors, an energy storage and 2 extractors), the enemy zone's edge as
-- published (60), the time to the first wave as published before the test's timing (300) and after it (the prep), and
-- the enemy with nothing on the field. A solar collector and a grunt of the player's are then put in the zone: the
-- collector should be warned of (`zone_warned`), and both should be gone once the first wave has arrived, while the bot
-- lab outside it stands. Then every wave once all of it has come down (`waves`, missions.arriving): how many of each def
-- it brought, which should be what counterattack.luau says, the metal it is worth, which should grow to the final
-- wave's, and whether all of it came in at the far end, in the zone. The first wave is left alone until the second
-- arrives: its bots should have set off west
-- (`moved_west`); `route_widest_z` says whether a grunt of it went by a ramp (beyond 30) or the road down the face
-- (less). Each wave is otherwise destroyed outright as the next arrives, which should never win the game before the
-- final wave (`ended_early`); nor should the final wave a second after it has arrived. Destroying it then should: the
-- game ended, won, with the enemy among no winners.
local function overlook_defense(args: Args): Findings
	local prep = args.prep or 5
	local pace = args.pace or 0.3
	local loaded, err = maps.load({ mission = "counterattack" })
	assert(loaded, err)
	local prep_default = (hud_waves() :: mission_state.Waves).wave_in
	retime(prep, pace)
	local prep_published = (hud_waves() :: mission_state.Waves).wave_in
	ensure_team(OWN)
	local enemy = mission_state.enemy_team() :: TeamId
	local start = mission_map.here(mission_map.PLAYER_START)
	local commander = spawning.spawn_near("commander", OWN, heightmap.ground_position(start.X, start.Y), math.pi / 2)
	assert(commander ~= nil, "no room for the commander")
	advance(1)

	-- the setup
	local own: { [string]: number } = {}
	local wrecks: { [string]: number } = {}
	local extractors_on_spots = 0
	local enemy_things = 0
	local lab: Entity? = nil
	for _, entity in state.all() do
		if entity.kind == "wreck" and below_cliff(entity.position) and entity.wreck ~= nil then
			local def_name = entity.wreck.source_def_name
			wrecks[def_name] = (wrecks[def_name] or 0) + 1
		elseif entity.team == OWN and entity.alive then
			own[entity.def_name] = (own[entity.def_name] or 0) + 1
			if entity.def_name == "metal_extractor" and spots.multiplier_at(entity.position) ~= 1 then
				extractors_on_spots += 1
			elseif entity.def_name == "bot_lab" then
				lab = entity
			end
		elseif entity.team == enemy and entity.alive then
			enemy_things += 1
		end
	end
	local zone_x = mission_state.zone_x()
	local wave_count = (hud_waves() :: mission_state.Waves).waves

	-- the enemy zone
	local function in_zone(x: number, _z: number): boolean
		return x - 4 >= mission_forces.COUNTERATTACK_LAYOUT.zone_x
	end
	local zone_warned = false
	local stop_observing = notifications.on_sent(function(team_id: TeamId, notice: types.Notice)
		if team_id == OWN and notice.kind == "enemy_zone" then
			zone_warned = true
		end
	end)
	local zone_solar =
		spawning.spawn_near("solar_collector", OWN, heightmap.ground_position(64, -6), -math.pi / 2, in_zone) :: Entity
	local zone_grunt =
		spawning.spawn_near("grunt", OWN, heightmap.ground_position(64, 8), -math.pi / 2, in_zone) :: Entity
	advance(1)
	stop_observing()
	local zone_things_before = zone_solar.alive and zone_grunt.alive

	-- the waves
	local seen: { [number]: boolean } = {}
	local waves: { Findings } = {}
	local first_bots: { [Entity]: number } = {}
	local first_bot_count = 0
	local route_widest_z = 0
	local moved_west = 0
	local zone_cleared: boolean? = nil
	local ended_early = false
	local arrived = 0
	-- which wave each of the enemy's units came with, and the wave still coming down, to be tallied once all of it has
	local wave_of: { [Entity]: number } = {}
	-- the enemy's units that came down outside the zone
	local came_outside: { [Entity]: boolean } = {}
	local tallying = 0
	advance(prep + 120 * pace + 1, function()
		if game_phase.phase() == "ended" then
			ended_early = true
		end
		local wave_now = hud_wave()
		if wave_now > arrived then
			arrived = wave_now
			tallying = wave_now
			if arrived == 1 then
				zone_cleared = zone_solar.alive == false and zone_grunt.alive == false
			elseif arrived == 2 then
				for bot, x in first_bots do
					if bot.position.X < x - 3 then
						moved_west += 1
					end
				end
			end
			-- the waves before this one go, but the first is watched setting off until the second comes
			for entity, wave in wave_of do
				if entity.alive and wave < arrived then
					damage.apply(entity, 1e9, nil)
				end
			end
		end
		for _, entity in state.all() do
			if entity.team ~= enemy or entity.kind ~= "unit" or seen[entity.id] == true then
				continue
			end
			seen[entity.id] = true
			wave_of[entity] = arrived
			if entity.position.X < mission_forces.COUNTERATTACK_LAYOUT.zone_x then
				came_outside[entity] = true
			end
			local def = entity.def
			if arrived == 1 and unit_defs.is_air(def) == false and unit_defs.is_vehicle(def) == false then
				first_bots[entity] = entity.position.X
				first_bot_count += 1
			end
			if arrived == 1 and entity.def_name == "grunt" and route_widest_z == 0 then
				for _, order in entity.orders do
					if order.position ~= nil then
						route_widest_z = math.max(route_widest_z, math.abs(order.position.Z))
					end
				end
			end
		end
		if tallying == 0 or missions.arriving() > 0 then
			return
		end
		local counts: { [string]: number } = {}
		local metal = 0
		local outside_zone = 0
		for entity, wave in wave_of do
			if wave ~= tallying then
				continue
			end
			counts[entity.def_name] = (counts[entity.def_name] or 0) + 1
			metal += entity.def.metal_cost
			if came_outside[entity] == true then
				outside_zone += 1
			end
		end
		local expected = wave_units(tallying)
		local as_expected = true
		for def_name, count in expected do
			if counts[def_name] ~= count then
				as_expected = false
			end
		end
		for def_name in counts do
			if expected[def_name] == nil then
				as_expected = false
			end
		end
		table.insert(waves, {
			counts = counts,
			metal = metal,
			outside_zone = outside_zone,
			as_expected = as_expected,
		})
		tallying = 0
	end)
	local final_arrived = hud_wave() == #mission_forces.COUNTERATTACK_WAVES
	local wave_in_after = (hud_waves() :: mission_state.Waves).wave_in
	advance(1)
	local phase_before_clear = game_phase.phase()
	destroy_all(enemy)
	advance(1)
	local winners = game_phase.winners()

	local escalates = #waves > 1
	local types_seen: { [string]: boolean } = {}
	for index, wave in waves do
		for def_name in wave.counts do
			types_seen[def_name] = true
		end
		if index > 1 and wave.metal < waves[index - 1].metal then
			escalates = false
		end
	end
	local every_type = true
	for _, def_name in COUNTERATTACK_DEFS do
		if types_seen[def_name] ~= true then
			every_type = false
		end
	end
	local waves_ok = #waves == wave_count
	for _, wave in waves do
		if wave.as_expected ~= true or wave.outside_zone ~= 0 then
			waves_ok = false
		end
	end

	return {
		own = own,
		extractors_on_spots = extractors_on_spots,
		wrecks = wrecks,
		enemy_at_start = enemy_things,
		zone_x = zone_x,
		prep_default = prep_default,
		prep_published = prep_published,
		wave_count = wave_count,
		zone_warned = zone_warned,
		zone_cleared = zone_cleared,
		lab_standing = lab ~= nil and lab.alive,
		waves = waves,
		every_type = every_type,
		escalates = escalates,
		first_bots = first_bot_count,
		moved_west = moved_west,
		route_widest_z = round(route_widest_z, 1),
		ended_early = ended_early,
		final_arrived = final_arrived,
		wave_in_after = wave_in_after,
		phase_before_clear = phase_before_clear,
		phase = game_phase.phase(),
		result = missions.result(),
		winners = winners,
		pass = own.commander == 1
			and own.metal_extractor == 4
			and extractors_on_spots == 4
			and own.solar_collector == 6
			and own.bot_lab == 1
			and own.graverobber == 2
			and own.thug == 6
			and own.aggravator == 4
			and wrecks.guard == 8
			and wrecks.solar_collector == 4
			and wrecks.grunt == nil
			and wrecks.bot_lab == nil
			and wrecks.energy_storage == 1
			and wrecks.metal_extractor == 2
			and enemy_things == 0
			and zone_x == mission_forces.COUNTERATTACK_LAYOUT.zone_x
			and prep_default == mission_forces.COUNTERATTACK_LAYOUT.prep_seconds
			and prep_published == prep
			and zone_things_before
			and zone_warned
			and zone_cleared == true
			and lab ~= nil
			and lab.alive
			and waves_ok
			and every_type
			and escalates
			and moved_west > 0
			and ended_early == false
			and final_arrived
			and wave_in_after == nil
			and phase_before_clear == "playing"
			and game_phase.phase() == "ended"
			and missions.result() == "won"
			and table.find(winners, enemy) == nil,
	}
end

-- The counterattack's way to hold (server/missions/counterattack.luau, resurrection.luau): the old base's guards, raised from their wrecks by
-- rezbots and turned on the waves. Loaded as overlook_defense loads it, with the usual five minutes to prepare. No wreck
-- of the old base should lie in the enemy zone (`wrecks_in_zone` 0), and its guards' should number
-- OLD_GUARDS. One of the player's two graverobbers is sent down the ramp to raise the guard wreck
-- nearest it (`walker_raised`), and a graverobber put beside each of the others raises that one, the team's energy kept
-- full meanwhile: every wreck should come back as a finished guard of the player's where it lay (`raised`), and once its
-- rezbot is done, repaired whole by it (`repaired`), all of them below the cliff, where the guide counts them
-- (`guide_count`). Then the time to prepare is cut short, as the command bar's `counterattack_timing` does
-- (`wave_in_before` nearly 300, `retimed_wave_in` 3), and the first wave arrives: every raised
-- guard should still stand once it has (`survived_arrival`), and over the next `args.watch` seconds (20) from its
-- arrival, on the team's own energy, at least two of them should fire on it (`guards_firing`, `guard_shots`) and it
-- should lose units: of the `wave_size` of it counted as it arrived, `wave_lost` gone.
local function counterattack_rez(args: Args): Findings
	local layout = mission_forces.COUNTERATTACK_LAYOUT
	local watch = args.watch or 20
	local enemy = start_counterattack()

	-- the old base, and the player's graverobbers
	local wrecks_in_zone = 0
	local rezbots: { Entity } = {}
	for _, entity in state.all() do
		if entity.kind == "wreck" and below_cliff(entity.position) and entity.position.X >= layout.zone_x then
			wrecks_in_zone += 1
		elseif entity.alive and entity.team == OWN and entity.def_name == "graverobber" then
			table.insert(rezbots, entity)
		end
	end
	local wrecks = old_guard_wrecks()
	assert(#rezbots > 0, "the player has no graverobber")
	assert(#wrecks > 0, "the old base left no guard wrecks")

	-- the walker takes the wreck nearest it; one is put beside each of the rest
	local walker = rezbots[1]
	local nearest = 1
	for index, wreck in wrecks do
		if
			geometry.distance_2d(wreck.position, walker.position)
			< geometry.distance_2d(wrecks[nearest].position, walker.position)
		then
			nearest = index
		end
	end
	local sites: { Vector3 } = {}
	local rezzers: { Entity } = { walker }
	for index, wreck in wrecks do
		table.insert(sites, wreck.position)
		local raise_it: types.Order = { kind = "resurrect", position = nil, target_id = wreck.id }
		if index ~= nearest then
			local rezzer = spawn("graverobber", OWN, wreck.position.X - 5, wreck.position.Z)
			orders.issue(rezzer, { raise_it }, false, false)
			table.insert(rezzers, rezzer)
			continue
		end
		-- down the ramp, the way the client would have found for it
		local below = heightmap.ground_position(wreck.position.X - 8, wreck.position.Z)
		local chain = pathfinder.route(walker.def, walker.position, below, 6000)
		table.insert(chain, raise_it)
		orders.issue(walker, chain, false, false)
	end
	local walker_wreck = wrecks[nearest]
	local rez_started = now()
	local deadline = now() + 90
	while now() < deadline do
		local left = 0
		for _, wreck in wrecks do
			if wreck.alive then
				left += 1
			end
		end
		if left == 0 then
			break
		end
		advance(1, function()
			harness.set_bank(OWN, { energy = ensure_team(OWN).energy_capacity })
		end)
	end
	local rez_seconds = round(now() - rez_started, 1)
	-- and the rezbots repair what they raised
	local repair_deadline = now() + 30
	while now() < repair_deadline do
		local busy = false
		for _, rezzer in rezzers do
			if #rezzer.orders > 0 then
				busy = true
			end
		end
		if busy == false then
			break
		end
		advance(1)
	end

	-- what came back
	local guards: { Entity } = {}
	local repaired = 0
	for _, site in sites do
		for _, entity in state.all() do
			if
				entity.alive
				and entity.team == OWN
				and entity.def_name == "guard"
				and entity.state == "active"
				and geometry.distance_2d(entity.position, site) < 0.5
			then
				table.insert(guards, entity)
				if entity.health >= entity.max_health - 0.01 then
					repaired += 1
				end
				break
			end
		end
	end
	local guide_count = 0
	for _, entity in state.all() do
		if
			entity.alive
			and entity.team == OWN
			and entity.def_name == "guard"
			and entity.state == "active"
			and below_cliff(entity.position)
		then
			guide_count += 1
		end
	end

	-- the prep cut short, as the command bar's counterattack_timing does
	local wave_in_before = (hud_waves() :: mission_state.Waves).wave_in :: number
	retime(layout.prep_seconds - wave_in_before + 3, nil)
	local retimed_wave_in = (hud_waves() :: mission_state.Waves).wave_in

	-- the first wave, counted the tick it arrives, before the guards have had a shot at it
	local survived_arrival: boolean? = nil
	local shots_before: { [Entity]: number } = {}
	local wave: { Entity } = {}
	local arrived_at: number? = nil
	local wave_deadline = now() + 10
	while arrived_at == nil and now() < wave_deadline do
		advance(tick_rate.TICK_DELTA)
		if hud_wave() ~= 1 then
			continue
		end
		arrived_at = now()
		survived_arrival = true
		for _, guard in guards do
			if guard.alive == false then
				survived_arrival = false
			end
			shots_before[guard] = shots_of(guard.id, 1)
		end
		-- the wave's units are in the main table even if they came down after this tick's flush
		for _, entity in state.all() do
			if entity.alive and entity.team == enemy and entity.kind == "unit" then
				table.insert(wave, entity)
			end
		end
	end
	advance(watch)
	local guard_shots = 0
	local guards_firing = 0
	for guard, before in shots_before do
		local fired = shots_of(guard.id, 1) - before
		guard_shots += fired
		if fired > 0 then
			guards_firing += 1
		end
	end
	local wave_lost = 0
	for _, entity in wave do
		if entity.alive == false then
			wave_lost += 1
		end
	end

	return {
		guard_wrecks = #wrecks,
		wrecks_in_zone = wrecks_in_zone,
		rezbots = #rezbots,
		walker_raised = walker_wreck.alive == false,
		rez_seconds = rez_seconds,
		raised = #guards,
		repaired = repaired,
		guide_count = guide_count,
		wave_in_before = wave_in_before,
		retimed_wave_in = retimed_wave_in,
		survived_arrival = survived_arrival,
		wave_size = #wave,
		guard_shots = guard_shots,
		guards_firing = guards_firing,
		wave_lost = wave_lost,
		energy = round((state.get_team(OWN) :: types.Team).energy, 0),
		pass = #wrecks == OLD_GUARDS
			and wrecks_in_zone == 0
			and #rezbots == 2
			and walker_wreck.alive == false
			and #guards == OLD_GUARDS
			and repaired == OLD_GUARDS
			and guide_count == OLD_GUARDS
			and wave_in_before > 200
			and retimed_wave_in == 3
			and survived_arrival == true
			and #wave > 0
			and guards_firing >= 2
			and wave_lost > 0,
	}
end

-- The counterattack played out with nobody at the controls, a rough measure of its balance: loaded as above, with
-- `args.raise` of the old base's guards (8 by default, 0 for none) raised at once, whole, as rezbots would have raised and
-- repaired them, the nearest the cliff first, `args.prep` seconds to prepare (5), and the waves at `args.pace` (1, as
-- played), up to wave `args.waves` (all of them). The player's army stands where it starts, firing at whatever comes
-- in reach, and nothing is built, raised or repaired. As each wave arrives (`waves`), and at the end (`final`): how many
-- raised guards, thugs and aggravators are standing, whether the commander is, the team's energy, and how many of the
-- enemy's units are on the field, and how many of those are left over from the waves before it (`leftover`). The run
-- ends `args.seconds` (90) after the last wave asked for, or sooner once the game is: `result` is then "won", "lost" or
-- nil, with `seconds` of game played. `starved_seconds` is how long the team's energy was all but gone. It should have
-- the balance BALANCE_HOLD_WAVE and the rest describe; any other number raised, or another pace, has no balance to hold
-- to, and is only reported, as a diagnostic.
local function counterattack_balance(args: Args): Findings
	local raise = args.raise or 8
	local prep = args.prep or 5
	local pace = args.pace or 1
	local last_wave = math.min(args.waves or #mission_forces.COUNTERATTACK_WAVES, #mission_forces.COUNTERATTACK_WAVES)
	local extra = args.seconds or 90
	local enemy = start_counterattack()
	local team = state.get_team(OWN) :: types.Team

	local raised: { Entity } = {}
	for index, wreck in old_guard_wrecks() do
		if index > raise then
			break
		end
		local guard = state.create_entity("guard", OWN, wreck.position, wreck.facing, "active")
		-- whole, as the rezbots that raised it would have repaired it
		guard.health = guard.max_health
		deaths.destroy(wreck, "removed")
		table.insert(raised, guard)
	end
	retime(prep, pace)

	local function census(): Findings
		local found: Findings = { guards = 0, thugs = 0, aggravators = 0, commander = false, enemies = 0 }
		for _, guard in raised do
			if guard.alive then
				found.guards += 1
			end
		end
		for _, entity in state.all() do
			if entity.alive == false then
				continue
			end
			if entity.team == OWN then
				if entity.def_name == "thug" then
					found.thugs += 1
				elseif entity.def_name == "aggravator" then
					found.aggravators += 1
				elseif unit_defs.is_commander(entity.def) then
					found.commander = true
				end
			elseif entity.team == enemy and entity.kind == "unit" then
				found.enemies += 1
			end
		end
		found.energy = round(team.energy, 0)
		return found
	end

	local waves: { Findings } = {}
	local seen = 0
	local starved = 0
	local started = now()
	local deadline = now() + prep + mission_forces.COUNTERATTACK_WAVES[last_wave].at * pace + extra
	while now() < deadline and game_phase.phase() ~= "ended" do
		advance(1, function()
			if team.energy < 20 then
				starved += tick_rate.TICK_DELTA
			end
			local wave_now = hud_wave()
			if wave_now > seen then
				seen = wave_now
				local found = census()
				found.wave = wave_now
				local size = 0
				for _, count in wave_units(wave_now) do
					size += count
				end
				found.leftover = found.enemies - size
				table.insert(waves, found)
			end
		end)
	end

	-- the balance asked for, by the census as each wave arrived
	local function at_wave(index: number): Findings?
		for _, found in waves do
			if found.wave == index then
				return found
			end
		end
		return nil
	end
	-- only the usual pace, with all the old guards raised or none, has a balance to hold to; any other run only reports
	local pass: boolean? = nil
	if pace == 1 and #raised >= OLD_GUARDS then
		local hold = at_wave(BALANCE_HOLD_WAVE)
		pass = hold ~= nil and hold.guards + hold.thugs + hold.aggravators > 0 and hold.leftover <= BALANCE_MAX_LEFTOVER
	elseif pace == 1 and #raised == 0 then
		local overrun = at_wave(BALANCE_OVERRUN_WAVE)
		-- lost outright before it came is overrun too
		pass = if overrun ~= nil then overrun.thugs + overrun.aggravators == 0 else missions.result() == "lost"
	end

	return {
		diagnostic = if pass == nil then true else nil,
		raise = #raised,
		pace = pace,
		waves = waves,
		final = census(),
		result = missions.result(),
		seconds = round(now() - started, 0),
		starved_seconds = round(starved, 1),
		pass = pass,
	}
end

-- The mission_load command's work (maps.load with a mission): the tutorial loaded, the game then ended as though it had been
-- won, and the overlook loaded over it. The overlook should be what is played (`mission`), with its enemy's 8 guards
-- and no grunts (it has none, so any would be the tutorial's enemy's) and nothing left of the tutorial's boulder, its enemy playing as the tutorial's did (no empty
-- team left behind), and the game playing again with no winners. A mission there is not should be refused.
local function load_mission(_args: Args): Findings
	local tutorial_ok, tutorial_err = maps.load({ mission = "tutorial" })
	local tutorial_enemy = mission_state.enemy_team()
	local boulder_before = find_boulder() ~= nil
	game_phase.set_ended({ OWN }, "test")
	local ended = game_phase.phase()
	local teams_before = 0
	for _ in state.all_teams() do
		teams_before += 1
	end

	local ok, err = maps.load({ mission = "overlook" })
	advance(1)
	local counts: { [string]: number } = {}
	for _, entity in state.all() do
		if entity.kind == "unit" or entity.kind == "building" then
			local key = `{entity.team}:{entity.def_name}`
			counts[key] = (counts[key] or 0) + 1
		end
	end
	local teams_after = 0
	for _ in state.all_teams() do
		teams_after += 1
	end
	local enemy = mission_state.enemy_team()
	local refused, refusal = maps.load({ mission = "nowhere" })
	return {
		tutorial_loaded = tutorial_ok,
		tutorial_error = tutorial_err,
		boulder_before = boulder_before,
		phase_after_win = ended,
		loaded = ok,
		error = err,
		mission = missions.mission(),
		preset = (map_state.get() :: map_state.MapState).preset,
		tutorial_enemy = tutorial_enemy,
		enemy = enemy,
		teams_before = teams_before,
		teams_after = teams_after,
		counts = counts,
		boulder_after = find_boulder() ~= nil,
		phase = game_phase.phase(),
		winners = game_phase.winners(),
		refused = refused == false,
		refusal = refusal,
		pass = tutorial_ok
			and boulder_before
			and ended == "ended"
			and ok
			and missions.mission() == "overlook"
			and enemy ~= nil
			and enemy == tutorial_enemy
			and teams_after == teams_before
			and counts[`{enemy}:guard`] == 8
			and counts[`{enemy}:grunt`] == nil
			and counts[`{harness.NEUTRAL}:tutorial_boulder`] == nil
			and find_boulder() == nil
			and game_phase.phase() == "playing"
			and #game_phase.winners() == 0
			and refused == false,
	}
end

-- The vote on going on to the next campaign mission (campaign_exit.tally): carried once more than half of the voters
-- here agree, one press when there is only one of them, and someone who leaves counted neither for nor against it. The
-- tally alone, with made-up user ids; the vote as players drive it is campaign_vote_flow's.
local function campaign_vote(_args: Args): Findings
	local function carried(voters: { number }, agreeing: { number }): boolean
		local set: { [number]: boolean } = {}
		for _, user_id in agreeing do
			set[user_id] = true
		end
		local count, needed = campaign_exit.tally(voters, set)
		return count >= needed
	end
	local cases: { { name: string, voters: { number }, agreeing: { number }, carried: boolean } } = {
		{ name = "alone, pressed", voters = { 1 }, agreeing = { 1 }, carried = true },
		{ name = "alone, not pressed", voters = { 1 }, agreeing = {}, carried = false },
		{ name = "1 of 2", voters = { 1, 2 }, agreeing = { 1 }, carried = false },
		{ name = "2 of 2", voters = { 1, 2 }, agreeing = { 1, 2 }, carried = true },
		{ name = "1 of 3", voters = { 1, 2, 3 }, agreeing = { 2 }, carried = false },
		{ name = "2 of 3", voters = { 1, 2, 3 }, agreeing = { 1, 3 }, carried = true },
		{ name = "2 of 4", voters = { 1, 2, 3, 4 }, agreeing = { 1, 2 }, carried = false },
		{ name = "3 of 4", voters = { 1, 2, 3, 4 }, agreeing = { 1, 2, 4 }, carried = true },
		-- 1 of 3 agreed, and one who had not left: 1 of 2 is still not more than half
		{ name = "1 of 3, a holdout left", voters = { 1, 2 }, agreeing = { 1 }, carried = false },
		-- 1 of 3 agreed, and both who had not left: the one left carries it
		{ name = "1 of 3, both holdouts left", voters = { 1 }, agreeing = { 1 }, carried = true },
		-- 2 of 3 agreed, and one of them left: their agreeing goes with them
		{ name = "2 of 3, one who agreed left", voters = { 2, 3 }, agreeing = { 1, 2 }, carried = false },
	}
	local wrong: { string } = {}
	for _, case in cases do
		if carried(case.voters, case.agreeing) ~= case.carried then
			table.insert(wrong, case.name)
		end
	end
	return {
		pass = #wrong == 0,
		cases = #cases,
		wrong = wrong,
	}
end

-- The vote on going on to the next mission as players drive it (server/campaign_exit.luau): the tutorial won by a team
-- two players are seated on, one of them agrees (CampaignVote), which is 1 of 2, and leaves the vote open; a player
-- on the enemy's team, who has nothing to vote on, is refused and told so; then the other voter leaves, and the one
-- left carries it, and is told they are being sent on, and the next mission, the overlook, is played.
local function campaign_vote_flow(_args: Args): Findings
	local enemy = set_up_mission "tutorial"
	local first = harness.join(OWN)
	local second = harness.join(OWN)
	advance(1)
	destroy_all(enemy)
	advance(1)
	local result = missions.result()
	local opened = campaign_exit.stage()

	harness.send("CampaignVote", first, true)
	local after_one = campaign_exit.stage()
	local published = mission_state.vote()
	local outsider = harness.join(enemy)
	harness.send("CampaignVote", outsider, true)
	local outsider_told = harness.told(outsider, "CampaignChoice")
	local refused = #outsider_told == 1 and outsider_told[1][1].stage == "failed"

	-- the second voter leaves, as the server's player stages have it (bootstrap.luau)
	campaign_exit.player_removing(second)
	players.forget(second)
	local waited = 0
	while missions.mission() ~= "overlook" and waited < 100 do
		harness.settle()
		waited += 1
	end
	local first_told = harness.told(first, "CampaignChoice")
	local sent = #first_told == 1 and first_told[1][1].stage == "sending"
	return {
		result = result,
		opened = opened,
		after_one = after_one,
		published = published,
		refused = refused,
		sent = sent,
		mission = missions.mission(),
		stage = campaign_exit.stage(),
		pass = result == "won"
			and opened == "open"
			and after_one == "open"
			and published ~= nil
			and published.needed == 2
			and #published.agreed == 1
			and refused
			and sent
			and missions.mission() == "overlook"
			and campaign_exit.stage() == nil,
	}
end

-- What a team may build is what the players seated on it have unlocked (server/unlocks.luau): a new player's team is held
-- to the campaign's starting unlocks, and stays held to them once they have left; a team nobody has been seated on (an
-- AI's, say) is held to nothing; and a player moved to another team is held there, and no longer counts for the one
-- they left, which is then held to the starting unlocks alone.
local function unlock_seats(_args: Args): Findings
	local starting = campaign.starting_unlocks()
	local locked_def: string? = nil
	local names: { string } = {}
	for name in unit_defs.defs do
		table.insert(names, name)
	end
	table.sort(names)
	for _, name in names do
		if campaign.is_lockable(name) and starting[name] == nil then
			locked_def = name
			break
		end
	end
	local locked = locked_def :: string
	local player = harness.join(OWN)
	local held = build_rules.allows(OWN, locked) == false and build_rules.allows(OWN, "grunt")
	players.forget(player)
	local held_after_leaving = build_rules.allows(OWN, locked) == false
	local unseated_free = build_rules.allows(harness.BYSTANDER, locked)
	local mover = harness.join(harness.ALLY)
	players.move(mover, harness.ENEMY)
	local moved_held = build_rules.allows(harness.ENEMY, locked) == false
	local left_held = build_rules.allows(harness.ALLY, locked) == false
	return {
		locked_def = locked,
		held = held,
		held_after_leaving = held_after_leaving,
		unseated_free = unseated_free,
		moved_held = moved_held,
		left_held = left_held,
		pass = held and held_after_leaving and unseated_free and moved_held and left_held,
	}
end

-- The names in `set`, sorted, as one line to compare.
local function names_of(set: { [string]: boolean }): string
	return table.concat(campaign_progress.list_of(set), ",")
end

-- A player's campaign progress as it is stored and changed (shared/campaign_progress.luau): a change is applied to
-- what is stored at that moment, so a mission finished in one place and saved there is kept when another place, which
-- read the progress before, saves a second; what is stored reads back as it was; a mission there is not changes
-- nothing; and relocking keeps what was finished.
local function progress_transitions(_args: Args): Findings
	local first, second = campaign.MISSIONS[1], campaign.MISSIONS[2]
	-- the game read a new player's progress, and meanwhile the lobby saved the first mission finished
	local stored = campaign_progress.complete(campaign_progress.new(), first.id, false)
	-- the game's save of the second is applied to what is stored now
	local saved = campaign_progress.complete(stored, second.id, false)
	local kept_both = saved.completed[first.id] == true and saved.completed[second.id] == true
	local unlocked_both = saved.unlocks[first.unlocks[1]] == true and saved.unlocks[second.unlocks[1]] == true
	local round_trip = campaign_progress.decode(campaign_progress.encode(saved))
	local same = names_of(round_trip.completed) == names_of(saved.completed)
		and names_of(round_trip.unlocks) == names_of(saved.unlocks)
	local unchanged = campaign_progress.complete(saved, "nowhere", false) == saved
	local relocked = campaign_progress.relock(saved)
	local starting = names_of(campaign.starting_unlocks())
	return {
		kept_both = kept_both,
		unlocked_both = unlocked_both,
		round_trip = same,
		unknown_unchanged = unchanged,
		relocked_to_start = names_of(relocked.unlocks) == starting,
		relock_keeps_completed = relocked.completed[first.id] == true,
		pass = kept_both
			and unlocked_both
			and same
			and unchanged
			and names_of(relocked.unlocks) == starting
			and relocked.completed[first.id] == true,
	}
end

-- How many of `team`'s units and buildings stand, of `def_name` if it is given.
local function standing_of(team: TeamId, def_name: string?): number
	local count = 0
	for _, entity in state.all() do
		if
			entity.team == team
			and entity.alive
			and (entity.kind == "unit" or entity.kind == "building")
			and (def_name == nil or entity.def_name == def_name)
		then
			count += 1
		end
	end
	return count
end

-- Puts the player's commander down at the first start box's usual start, as a player choosing there would.
local function commander_at_first_start(): Entity
	ensure_team(OWN)
	local spot = starts.default_spot(1)
	local commander = spawning.spawn_near("commander", OWN, heightmap.ground_position(spot.X, spot.Y), 0)
	assert(commander ~= nil, "no room for the commander")
	return commander
end

-- Prairie Skirmish (server/missions/skirmish.luau, on the prairie map), loaded as the mission_load command would, with
-- the player's commander put down at the first start box's usual start, as a player choosing there would. Before
-- anything steps the enemy should have nothing on the field (`enemy_before`, 0); a second later the AI should play it
-- (`is_ai`) by the mission's profile (`profile`, "passive"), with one commander (`enemy_commanders`) far from the
-- player's (`apart`, over 100 studs), and the game still going. After `args.seconds` (60) it should have built something
-- besides (`enemy_things` over 1). Killing its commander should then win: the game ended, won, with the enemy among no
-- winners. Loading the tutorial afterwards should leave the AI no longer playing the old enemy (`released`).
local function prairie_skirmish(args: Args): Findings
	local seconds = args.seconds or 60
	local loaded, err = maps.load({ mission = "prairie" })
	assert(loaded, err)
	local enemy = mission_state.enemy_team() :: TeamId
	local enemy_before = standing_of(enemy, nil)
	local commander = commander_at_first_start()
	advance(1)

	local profile = ai.profile_of(enemy)
	local enemy_commander = harness.commander_of(enemy)
	local apart = if enemy_commander ~= nil
		then geometry.distance_2d(enemy_commander.position, commander.position)
		else 0
	local enemy_commanders = standing_of(enemy, "commander")
	local phase_seated = game_phase.phase()
	advance(seconds)
	local enemy_things = standing_of(enemy, nil)
	local phase_before_kill = game_phase.phase()

	if enemy_commander ~= nil and enemy_commander.alive then
		damage.apply(enemy_commander, 1e9, nil)
	end
	advance(1)
	local phase = game_phase.phase()
	local result = missions.result()
	local winners = game_phase.winners()

	local tutorial_ok = maps.load({ mission = "tutorial" })
	local released = ai.is_ai(enemy) == false

	return {
		enemy = enemy,
		enemy_before = enemy_before,
		is_ai = profile ~= nil,
		profile = if profile ~= nil then profile.name else nil,
		enemy_commanders = enemy_commanders,
		apart = round(apart, 1),
		phase_seated = phase_seated,
		enemy_things = enemy_things,
		phase_before_kill = phase_before_kill,
		phase = phase,
		result = result,
		winners = winners,
		tutorial_ok = tutorial_ok,
		released = released,
		pass = enemy_before == 0
			and profile ~= nil
			and profile.name == "passive"
			and enemy_commanders == 1
			and apart > 100
			and phase_seated == "playing"
			and enemy_things > 1
			and phase_before_kill == "playing"
			and phase == "ended"
			and result == "won"
			and table.find(winners, enemy) == nil
			and tutorial_ok
			and released,
	}
end

-- The campaign's hard modes (campaign.Mission's `hard_mode`), each loaded as `mission_load <id> true` would. Keys: the
-- overlook's hard mode should be named "overlook_hard" and parse back (`keys`), the tutorial should have none, and each
-- hard mission a mode of its own (`modes`). The overlook in hard mode should be played hard (missions.hard) with one
-- agitator in the enemy's base (`overlook_hard_agitators`, 1), which should shell a thug at the cliff's edge, out of
-- every guard's reach, within 12 seconds (`thug_hurt`), and none in its normal mode. The counterattack should have 15
-- waves in hard mode, the 9th bringing a pounder and the 15th four januses, and 8 in its normal mode. Prairie
-- Skirmish's AI should play by sim_barb in hard mode and passive in its normal one. What a hard win unlocks should add
-- the hard mode's unlocks to the mission's. Loading the tutorial last should leave nothing played hard.
local function hard_modes(_args: Args): Findings
	local overlook_mission, overlook_hard = campaign.parse_key "overlook_hard"
	local tutorial_hard = campaign.parse_key "tutorial_hard"
	local keys = campaign.key("overlook", true) == "overlook_hard"
		and overlook_mission ~= nil
		and overlook_mission.id == "overlook"
		and overlook_hard
		and tutorial_hard == nil
	local modes = true
	for _, mission in campaign.MISSIONS do
		local mode = game_modes.campaign_mode(mission.id, true)
		if
			mission.hard_mode ~= (mode ~= nil) or (mode ~= nil and (mode.hard ~= true or mode.mission ~= mission.id))
		then
			modes = false
		end
		local normal = game_modes.campaign_mode(mission.id, false)
		if normal == nil or normal.hard then
			modes = false
		end
	end

	local function enemy_agitators(): number
		return standing_of(mission_state.enemy_team() :: TeamId, "agitator")
	end
	local overlook_hard_ok = maps.load({ mission = "overlook", hard = true })
	local overlook_played_hard = missions.hard()
	local overlook_hard_agitators = enemy_agitators()
	ensure_team(OWN)
	local edge_x = mission_map.brink_x(0) - 5
	local target = spawning.spawn_near("thug", OWN, heightmap.ground_position(edge_x, 0), math.pi / 2)
	assert(target ~= nil, "no room for the thug at the edge")
	local target_health = target.health
	advance(12)
	local thug_hurt = target.alive == false or target.health < target_health
	maps.load({ mission = "overlook", hard = false })
	local overlook_played_hard_normal = missions.hard()
	local overlook_agitators = enemy_agitators()

	maps.load({ mission = "counterattack", hard = true })
	local hard_waves = (hud_waves() :: mission_state.Waves).waves
	maps.load({ mission = "counterattack", hard = false })
	local waves = (hud_waves() :: mission_state.Waves).waves
	local function units_of(wave: mission_forces.Wave, def_name: string): number
		local count = 0
		for _, each in wave.units do
			if each.def_name == def_name then
				count += each.count
			end
		end
		return count
	end
	local ninth_pounders = units_of(mission_forces.COUNTERATTACK_HARD_WAVES[9], "pounder")
	local fifteenth_januses = units_of(mission_forces.COUNTERATTACK_HARD_WAVES[15], "janus")

	local function prairie_profile(hard: boolean): string?
		maps.load({ mission = "prairie", hard = hard })
		commander_at_first_start()
		advance(1)
		local profile = ai.profile_of(mission_state.enemy_team() :: TeamId)
		return if profile ~= nil then profile.name else nil
	end
	local prairie_hard = prairie_profile(true)
	local prairie = prairie_profile(false)

	local overlook_def = campaign.get "overlook" :: campaign.Mission
	local hard_unlocks = campaign.unlocks_for(overlook_def, true)
	local normal_unlocks = campaign.unlocks_for(overlook_def, false)
	local unlocks = #hard_unlocks == #overlook_def.unlocks + #(overlook_def.hard_mode_unlocks or {})
		and table.find(hard_unlocks, "warden") ~= nil
		and table.find(normal_unlocks, "warden") == nil

	maps.load({ mission = "tutorial" })
	local tutorial_played_hard = missions.hard()

	return {
		keys = keys,
		modes = modes,
		overlook_hard_loaded = overlook_hard_ok,
		overlook_played_hard = overlook_played_hard,
		overlook_hard_agitators = overlook_hard_agitators,
		thug_hurt = thug_hurt,
		overlook_played_hard_normal = overlook_played_hard_normal,
		overlook_agitators = overlook_agitators,
		hard_waves = hard_waves,
		ninth_pounders = ninth_pounders,
		fifteenth_januses = fifteenth_januses,
		waves = waves,
		prairie_hard = prairie_hard,
		prairie = prairie,
		unlocks = unlocks,
		tutorial_played_hard = tutorial_played_hard,
		pass = keys
			and modes
			and overlook_hard_ok
			and overlook_played_hard
			and overlook_hard_agitators == 1
			and thug_hurt
			and overlook_played_hard_normal == false
			and overlook_agitators == 0
			and hard_waves == 15
			and ninth_pounders >= 1
			and fifteenth_januses == 4
			and waves == 8
			and prairie_hard == "sim_barb"
			and prairie == "passive"
			and unlocks
			and tutorial_played_hard == false,
	}
end

local TESTS: { [string]: Test } = {
	progress_transitions = { run = progress_transitions },
	prairie_skirmish = { run = prairie_skirmish },
	hard_modes = { run = hard_modes },
	tutorial_boulder = { run = tutorial_boulder },
	tutorial_victory = { run = tutorial_victory },
	overlook = { run = overlook },
	overlook_defense = { run = overlook_defense },
	wave_cleared = { run = wave_cleared },
	counterattack_rez = { run = counterattack_rez },
	counterattack_balance = { run = counterattack_balance },
	load_mission = { run = load_mission },
	campaign_vote = { run = campaign_vote },
	campaign_vote_flow = { run = campaign_vote_flow },
	unlock_seats = { run = unlock_seats },
}

return table.freeze(TESTS)
