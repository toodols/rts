--!strict
-- Tests of the scavengers (server/scavengers): their units hunting, their opening, their end, what they do about units
-- that can get nowhere, and a new map starting them over.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local teams = require(ReplicatedStorage.Shared.teams)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local starts = require(ReplicatedStorage.Shared.starts)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local map_state = require(ReplicatedStorage.Shared.map_state)

local state = require(ServerScriptService.Server.state)
local damage = require(ServerScriptService.Server.damage)
local deaths = require(ServerScriptService.Server.deaths)
local maps = require(ServerScriptService.Server.maps)
local scavengers = require(ServerScriptService.Server.scavengers)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local advance = harness.advance
local round = harness.round
local spawn = harness.spawn
local unkillable = harness.unkillable
local damage_to = harness.damage_to
local clear_world = harness.clear_world

type Entity = types.Entity
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

local SCAVENGERS = harness.SCAVENGERS
-- The most a hunting scavenger may spend pushing and getting nowhere, as against a cliff.
local MOST_STUCK = 5

-- Everything of the scavengers' that is alive and not a wreck, or only what is `def_name`.
local function scavenger_things(def_name: string?): { Entity }
	local found = {}
	for _, entity in state.all() do
		if
			entity.alive
			and entity.team == teams.SCAVENGER
			and entity.kind ~= "wreck"
			and (def_name == nil or entity.def_name == def_name)
		then
			table.insert(found, entity)
		end
	end
	return found
end

-- How many scavenger units there are.
local function scavenger_units(): number
	local count = 0
	for _, entity in scavenger_things(nil) do
		if entity.kind == "unit" then
			count += 1
		end
	end
	return count
end

-- A scavenger `args.unit` (a grunt by default) hunting a solar collector it cannot kill, for `args.seconds` (60 by
-- default) each time: once with the collector up on the plateau and the scavenger on the low ground below it, and
-- once on open ground. For each: how long it spent trying to go somewhere and getting nowhere (pushing into a cliff,
-- say), how near it got, how high it ended up compared with the collector, and whether it managed to shoot it. It should
-- find its way to it and shoot it both times, stuck no longer than MOST_STUCK.
local function scavenger_hunt(args: Args): Findings
	local function attempt(target_x: number, target_z: number, from_x: number, from_z: number): Findings
		local target = unkillable(spawn("solar_collector", OWN, target_x, target_z))
		local hunter = spawn(args.unit or "grunt", teams.SCAVENGER, from_x, from_z)
		advance(tick_rate.TICK_DELTA)

		local travelled, nearest = 0, math.huge
		local last = hunter.position
		local watch, stuck = harness.stuck_watch(hunter)
		advance(args.seconds or 60, function()
			watch()
			travelled += (hunter.position - last).Magnitude
			last = hunter.position
			local offset = target.position - hunter.position
			nearest = math.min(nearest, Vector3.new(offset.X, 0, offset.Z).Magnitude)
		end)
		local findings = {
			alive = hunter.alive,
			seconds_stuck = round(stuck(), 2),
			travelled = round(travelled, 1),
			nearest = round(nearest, 1),
			height_below_target = round(target.position.Y - hunter.position.Y, 1),
			damage_to_target = round(damage_to(target), 0),
			ok = stuck() <= MOST_STUCK and damage_to(target) > 0,
		}
		clear_world()
		return findings
	end
	local up_on_plateau = attempt(140, -120, 190, -120)
	local open_ground = attempt(160, -40, 120, -40)
	return {
		up_on_plateau = up_on_plateau,
		open_ground = open_ground,
		pass = up_on_plateau.ok and open_ground.ok,
	}
end

-- The scavengers' opening. A commander in start box 1 and the gamemode on at progress 0: the first beacon should go up
-- in another start box, and they should have no units after `args.wait` seconds (30 by default), still short of the
-- progress they start at. Then at that progress, they should have some after 12 seconds; and of a grunt's wreck by the
-- beacon and another far from it, after long enough to come back, only the near one should be revived.
local function scavenger_opening(args: Args): Findings
	local home = starts.default_spot(1)
	spawn("commander", OWN, home.X, home.Y)
	scavengers.set_progress(0)
	local result: Findings = {}
	harness.with_switch(SCAVENGERS, true, function()
		advance(tick_rate.TICK_DELTA)

		local beacons = scavenger_things "scavenger_beacon"
		local beacon = beacons[1]
		assert(beacon ~= nil, "the scavengers put up no beacon")
		local box = 0
		for index = 1, starts.box_count() do
			if starts.in_box(index, beacon.position.X, beacon.position.Z) then
				box = index
				break
			end
		end

		advance(args.wait or 30)
		local units_before = scavenger_units()

		scavengers.set_progress(scavengers.SETTINGS.SPAWN_PROGRESS)
		advance(12)
		local units_after = scavenger_units()

		local toward_middle = -Vector3.new(beacon.position.X, 0, beacon.position.Z).Unit
		local near_at = beacon.position + toward_middle * 60
		local near = harness.wreck_of("grunt", near_at.X, near_at.Z)
		local far_at = beacon.position + toward_middle * (scavengers.SETTINGS.REVIVE_RANGE + 150)
		local far = harness.wreck_of("grunt", far_at.X, far_at.Z)
		advance(scavengers.SETTINGS.REVIVE_SECONDS + 2)

		result = {
			beacons = #beacons,
			boxes = starts.box_count(),
			beacon_box = box,
			units_before_progress = units_before,
			units_after_progress = units_after,
			near_wreck_revived = near.alive == false,
			far_wreck_revived = far.alive == false,
			far_wreck_progress = if far.wreck ~= nil then round(far.wreck.resurrect_progress, 1) else -1,
			pass = box ~= 0
				and box ~= 1
				and units_before == 0
				and units_after > 0
				and near.alive == false
				and far.alive,
		}
	end)
	return result
end

-- The end of a game against the scavengers, at the difficulty's `args.health` (5, brutal, by default) and progress
-- `args.progress` (0.3 by default). Their first beacon's health, grown with the progress, and a unit it makes, with the
-- difficulty's; then the beacon destroyed, which should move the progress on and, being the last beacon, bring their
-- boss, at the difficulty's health. Then the boss destroyed: the game should end, won by the player.
local function scavenger_endgame(args: Args): Findings
	local health = args.health or 5
	local at_progress = args.progress or 0.3
	-- a team of its own, as a player has, so there is someone to win
	harness.ensure_team(OWN)
	local home = starts.default_spot(1)
	unkillable(spawn("commander", OWN, home.X, home.Y))
	scavengers.set_health_multiplier(health)
	scavengers.set_progress(at_progress)
	local result: Findings = {}
	harness.with_switch(SCAVENGERS, true, function()
		advance(tick_rate.TICK_DELTA)

		local beacon = scavenger_things("scavenger_beacon")[1]
		assert(beacon ~= nil, "the scavengers put up no beacon")
		local beacon_health = beacon.max_health
		local beacon_expected = unit_defs.max_health(unit_defs.get "scavenger_beacon")
			* (1 + scavengers.SETTINGS.BEACON_HEALTH_GROWTH * scavengers.progress())

		advance(scavengers.SETTINGS.SPAWN_INTERVAL + 1)
		local unit: Entity? = nil
		for _, entity in scavenger_things(nil) do
			if entity.kind == "unit" then
				unit = entity
				break
			end
		end

		local before = scavengers.progress()
		damage.apply(beacon, beacon.health + 1)
		advance(tick_rate.TICK_DELTA * 2)
		local after = scavengers.progress()
		local boss = scavenger_things("scavenger_boss")[1]

		local findings: Findings = {
			beacon_health = round(beacon_health, 0),
			beacon_health_expected = round(beacon_expected, 0),
			unit = if unit ~= nil then unit.def_name else "none",
			unit_health_multiple = if unit ~= nil
				then round(unit.max_health / unit_defs.max_health(unit_defs.get(unit.def_name)), 2)
				else -1,
			progress_moved = round(after - before, 4),
			boss_came = boss ~= nil,
		}
		local findings_right = math.abs(beacon_health - beacon_expected) < 1
			and findings.unit_health_multiple == health
			and after > before
		if boss == nil then
			findings.pass = false
			result = findings
			return
		end
		findings.boss_health_multiple = round(boss.max_health / unit_defs.max_health(unit_defs.get "scavenger_boss"), 2)
		findings.phase_before_boss_dies = game_phase.phase()

		damage.apply(boss, boss.health + 1)
		advance(tick_rate.TICK_DELTA * 2)
		findings.phase = game_phase.phase()
		findings.winners = table.concat(game_phase.winners(), ",")
		findings.end_reason = game_phase.end_reason() or ""
		findings.pass = findings_right
			and findings.boss_health_multiple == health
			and findings.phase_before_boss_dies ~= "ended"
			and findings.phase == "ended"
			and table.find(game_phase.winners(), OWN) ~= nil
		result = findings
	end)
	return result
end

-- Scavengers that can get nowhere, on islands unless another `preset` is given: `args.count` grunts (2 by default) on
-- the island of start 3 with the only thing of a player's a commander on the island of start 1, which they cannot
-- kill. After `args.seconds` (130 by default), past `SCAVENGER_FUTILE_SECONDS`, the grunts should have been taken away,
-- leaving no wrecks, and what they were worth kept to be rerolled. Then with the gamemode on and a beacon by them, that
-- credit should be spent on something that can get across (`made_after` lists the beacon's own units too, which it
-- makes as it always does).
local function scavenger_stranded(args: Args): Findings
	local home = starts.center(1)
	local away = starts.center(3)
	unkillable(spawn("commander", OWN, home.X, home.Y))
	local grunt_ids = {}
	for index = 1, args.count or 2 do
		table.insert(grunt_ids, spawn("grunt", teams.SCAVENGER, away.X + index * 4, away.Y).id)
	end
	scavengers.set_progress(0.5)
	advance(args.seconds or 130)

	local wrecks = 0
	for _, entity in state.all() do
		if entity.alive and entity.kind == "wreck" then
			wrecks += 1
		end
	end
	local credit = scavengers.reroll_credit()
	local taken_away = 0
	for _, id in grunt_ids do
		if state.get(id) == nil then
			taken_away += 1
		end
	end
	local findings: Findings = {
		grunts_taken_away = taken_away,
		wrecks = wrecks,
		credit = round(credit, 2),
	}

	local before: { [number]: boolean } = {}
	for _, entity in scavenger_things(nil) do
		before[entity.id] = true
	end
	local made = {}
	local crossing = 0
	harness.with_switch(SCAVENGERS, true, function()
		scavengers.force_beacon(away.X + 30, away.Y)
		advance(3)
		for _, entity in scavenger_things(nil) do
			if before[entity.id] == nil and entity.kind == "unit" then
				local def = unit_defs.get(entity.def_name)
				local crosses = def.air ~= nil or unit_defs.tolerates_water(def, 0, 400)
				if crosses then
					crossing += 1
				end
				table.insert(made, `{entity.def_name}{if crosses then "" else " (cannot cross)"}`)
			end
		end
	end)
	findings.made_after = table.concat(made, ", ")
	findings.credit_after = round(scavengers.reroll_credit(), 2)
	findings.pass = taken_away == #grunt_ids
		and wrecks == 0
		and credit > 0
		and crossing > 0
		and scavengers.reroll_credit() < credit
	return findings
end

-- A new map is a new game against the scavengers: with a player's commander at the first start and the gamemode on at
-- progress `args.progress` (0.3), their first beacon goes up; the same map loaded again clears it away, which is not
-- destroying it, so the progress starts over at 0, with no beacon and no boss. With a commander down again the first
-- beacon goes up again, and destroyed by a disintegrator, which leaves its health as it was, it still moves the game on
-- and, being the last, brings their boss.
local function scavenger_new_map(args: Args): Findings
	local at_progress = args.progress or 0.3
	local home = starts.default_spot(1)
	local function commander()
		harness.ensure_team(OWN)
		unkillable(spawn("commander", OWN, home.X, home.Y))
	end
	local findings: Findings = {}
	harness.with_switch(SCAVENGERS, true, function()
		commander()
		scavengers.set_progress(at_progress)
		advance(tick_rate.TICK_DELTA)
		local before = scavengers.status()
		findings.beacons_before = before.beacons

		local preset = (map_state.get() :: map_state.MapState).preset
		local loaded, problem = maps.load({ preset = preset })
		assert(loaded, problem)
		local after = scavengers.status()
		findings.beacons_after = after.beacons
		findings.progress_after = round(after.progress, 4)
		findings.boss_after = after.boss

		commander()
		advance(tick_rate.TICK_DELTA)
		local beacon = scavenger_things("scavenger_beacon")[1]
		findings.beacon_again = beacon ~= nil
		if beacon == nil then
			return
		end
		local progress_before = scavengers.progress()
		deaths.destroy(beacon, "disintegrated")
		advance(tick_rate.TICK_DELTA * 2)
		findings.progress_moved = round(scavengers.progress() - progress_before, 4)
		findings.boss_came = scavengers.status().boss
	end)
	findings.pass = findings.beacons_before == 1
		and findings.beacons_after == 0
		and findings.progress_after == 0
		and findings.boss_after == false
		and findings.beacon_again == true
		and (findings.progress_moved or 0) > 0
		and findings.boss_came == true
	return findings
end

local TESTS: { [string]: Test } = {
	scavenger_hunt = { run = scavenger_hunt },
	scavenger_opening = { run = scavenger_opening },
	scavenger_endgame = { run = scavenger_endgame },
	scavenger_stranded = { run = scavenger_stranded, defaults = { preset = "islands" } },
	scavenger_new_map = { run = scavenger_new_map },
}

return table.freeze(TESTS)
