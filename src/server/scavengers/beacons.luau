--!strict
-- The scavengers' beacons. As the game begins a beacon stands in a start nobody took (`open_once`), and every few
-- minutes another goes up near one already standing, so that they spread out over the map (`run_schedule`). Once the
-- game is far enough along, every beacon keeps producing hostile units and defences around itself (`run`), so the more
-- beacons stand the more come; and what the units that got nowhere were worth is spent at them on units that can get
-- across (`run_reroll`). When the last beacon falls, or the game's progress runs out, their boss comes (boss.luau).
-- Where all of it goes down is sites.luau's.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local switches = require(ReplicatedStorage.Shared.switches)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local state = require(ServerScriptService.Server.state)
local deaths = require(ServerScriptService.Server.deaths)
local placement = require(ServerScriptService.Server.placement)
local spatial = require(ServerScriptService.Server.spatial)
local rng = require(ServerScriptService.Server.rng)

local settings = require(script.Parent.settings)
local progress = require(script.Parent.progress)
local roster = require(script.Parent.roster)
local units = require(script.Parent.units)
local sites = require(script.Parent.sites)
local boss = require(script.Parent.boss)
local snapshot = require(ServerScriptService.Server.snapshot)

type Entity = types.Entity
type EntityId = types.EntityId

-- What of the scavengers' is out this step, looked at once at its top (init.luau): how many units they have, which each
-- thing made adds to, and whether anyone but them has anything in the air.
export type Tally = {
	units: number,
	enemy_air: boolean,
}

-- Units and defences are made on separate clocks, so that a beacon ringed with all the defences it will take goes on
-- making units.
type Beacon = {
	next_unit_at: number,
	next_defense_at: number,
	-- whether it floats on the sea, and makes ships, or stands on the land
	sea: boolean,
	-- whether it makes things before the game has got to settings.SPAWN_PROGRESS, as a forced one does
	eager: boolean,
	-- where it stood, for their boss to come there if it is the last
	position: Vector3,
	-- whether it was destroyed, rather than only cleared away with the map, once it is gone (`note_destroyed`)
	destroyed: boolean,
}

local BEACON_ATTEMPTS = 40
local BEACON_RETRY_DELAY = 10
-- Units appear this far from the middle of a beacon, and defences a little further out, so that a defence never boxes
-- the beacon's own units in.
local UNIT_RING_START = 12
local DEFENSE_RING_START = 16
-- A defence counts toward a beacon's limit when it stands this close to it.
local DEFENSE_SCAN_RADIUS = 60
-- How often what the units that got nowhere were worth is spent (`run_reroll`).
local REROLL_INTERVAL = 1

-- Whether the game has begun, as far as the scavengers are concerned: the first step anything of a player's stands (see
-- `open_once`).
local opened = false
-- When the next beacon goes up; nil until the beacons start making things, which is when the gaps start.
local next_beacon_at: number? = nil
local beacons: { [EntityId]: Beacon } = {}
local next_reroll_at = 0

local function is_scavenger(entity: Entity): boolean
	return entity.team == teams.SCAVENGER
end

-- Seconds between one beacon's units, or its defences: `interval` stretched for a sea beacon and by the spawn rate.
local function spawn_gap(interval: number, sea: boolean): number
	local multiplier = if sea then settings.SEA_SPAWN_MULTIPLIER else 1
	return interval * multiplier / settings.SPAWN_RATE
end

-- Makes a `def_name` of theirs at a free place round `around`, no nearer than `start`, with their difficulty's health,
-- `tally` counting it if it is a unit. Returns whether there was room.
local function make_near(def_name: string, around: Vector3, start: number, tally: Tally): boolean
	local spot = sites.spot_near(def_name, around, start)
	if spot == nil then
		return false
	end
	local made = state.create_entity(def_name, teams.SCAVENGER, spot.position, spot.facing, "active")
	progress.toughen(made)
	if made.kind == "unit" then
		tally.units += 1
	end
	return true
end

-- A beacon's health, which grows with the game's progress (settings.BEACON_HEALTH_GROWTH), keeping the share of it
-- the beacon has.
local function grow_beacon(beacon: Entity)
	local wanted = unit_defs.max_health(beacon.def) * (1 + settings.BEACON_HEALTH_GROWTH * progress.progress())
	if math.abs(wanted - beacon.max_health) < 1 then
		return
	end
	local fraction = beacon.health / beacon.max_health
	beacon.max_health = wanted
	beacon.health = wanted * fraction
end

-- Stands a beacon at `center`, a place already found for it, and sets it making things: `delay` seconds from now, once
-- the game is far enough along, or at once if it is `eager`.
local function place_beacon(center: Vector3, sea: boolean, delay: number, eager: boolean): Entity
	local beacon = state.create_entity(sites.beacon_def(sea).name, teams.SCAVENGER, center, 0, "active")
	local now = progress.now()
	beacons[beacon.id] = {
		next_unit_at = now + delay,
		next_defense_at = now + delay,
		sea = sea,
		eager = eager,
		position = beacon.position,
		destroyed = false,
	}
	grow_beacon(beacon)
	return beacon
end

-- The beacons that stand, as entities.
local function standing(): { Entity }
	local found: { Entity } = {}
	for id in beacons do
		local beacon = state.get(id)
		if beacon ~= nil and beacon.alive then
			table.insert(found, beacon)
		end
	end
	return found
end

local function count(): number
	local found = 0
	for _ in beacons do
		found += 1
	end
	return found
end

-- Puts a beacon down near one already standing, between settings.BEACON_SPACING and settings.BEACON_SPREAD from it,
-- so that they spread out from where they began; with none standing, or no room round any, anywhere on the map. Units
-- and defences come settings.INITIAL_SPAWN_DELAY after it goes up, and a sea one makes them less often. Returns
-- whether one went down: on a crowded map, or one with nowhere it will stand, it can fail to find room.
local function spawn_beacon(allow_sea: boolean): boolean
	local from = standing()
	local half_x, half_z = heightmap.half_extents()
	for attempt = 1, BEACON_ATTEMPTS * 2 do
		local x, z
		if attempt <= BEACON_ATTEMPTS and #from > 0 then
			local origin = from[rng.stream("scavengers"):NextInteger(1, #from)].position
			local angle = rng.stream("scavengers"):NextNumber(0, math.pi * 2)
			local distance = rng.stream("scavengers"):NextNumber(settings.BEACON_SPACING, settings.BEACON_SPREAD)
			x = origin.X + math.cos(angle) * distance
			z = origin.Z + math.sin(angle) * distance
		elseif attempt > BEACON_ATTEMPTS then
			x = rng.stream("scavengers"):NextNumber(-half_x, half_x)
			z = rng.stream("scavengers"):NextNumber(-half_z, half_z)
		else
			continue
		end
		local center, sea = sites.beacon_site(x, z, allow_sea)
		if center ~= nil then
			place_beacon(center, sea, settings.INITIAL_SPAWN_DELAY + spawn_gap(settings.SPAWN_INTERVAL, sea), false)
			return true
		end
	end
	return false
end

-- The game has begun: the scavengers take a start box nobody else was given, and their first beacon stands in it,
-- making nothing until the game has got to settings.SPAWN_PROGRESS. It goes up as near the box's start as it will
-- stand, on the land, so a player never faces an opening threat they have no way to reach. With every box taken, it
-- goes wherever there is room instead.
local function open()
	local index = sites.free_box()
	local center = if index ~= nil then sites.first_site(index) else nil
	if center ~= nil then
		place_beacon(center, false, 0, false)
		return
	end
	if spawn_beacon(false) == false then
		warn "the scavengers found nowhere to put their first beacon; the schedule will try again"
	end
end

-- The game begins for the scavengers on the first step anything of a player's stands, so a start one of them has is
-- never taken for free. With the gamemode off then, it is not opened later: turning it on part way just starts the
-- schedule.
local function open_once()
	if opened then
		return
	end
	opened = sites.anything_of_players()
	if opened and switches.is_on "scavengers" then
		open()
	end
end

-- Puts a beacon down at (x, z) regardless of players or roaming room, for testing: it still snaps to the nearest valid
-- land or sea spot the way spawn_beacon does, but skips the beacon site's other rules, and starts making things right
-- away, whatever the game's progress, rather than waiting. Returns it, if one went down; it can still fail if there is
-- nowhere for it to stand at all.
local function force_beacon(x: number, z: number): EntityId?
	local sea = heightmap.water_depth(x, z) > 0
	local def_name = sites.beacon_def(sea).name
	local center = placement.resolve_center(def_name, x, z, 0)
	if center == nil or placement.can_place(def_name, center, 0, nil) == false then
		return nil
	end
	return place_beacon(center, sea, 0, true).id
end

local function beacon_interval(): number
	return rng.stream("scavengers"):NextNumber(settings.BEACON_INTERVAL_MIN, settings.BEACON_INTERVAL_MAX)
end

-- Whether anyone but the scavengers has anything in the air, which is all a weapon that only hits aircraft is good for.
local function enemy_air_exists(): boolean
	for _, other in state.all() do
		if other.alive and other.kind == "unit" and is_scavenger(other) == false and unit_defs.is_air(other.def) then
			return true
		end
	end
	return false
end

-- The defences the scavengers have standing round `beacon`.
local function defenses_around(beacon: Entity): { Entity }
	local found: { Entity } = {}
	spatial.each_present(beacon.position, DEFENSE_SCAN_RADIUS, function(other: Entity): boolean?
		if
			other.state == "active"
			and is_scavenger(other)
			and other.kind == "building"
			and unit_defs.is_beacon(other.def) == false
		then
			table.insert(found, other)
		end
		return nil
	end)
	return found
end

-- The easiest of `present` to do without, the one with the least id of those as easy. One in the middle of an attack
-- is never the one, so nothing disappears in front of a player.
local function weakest_of(present: { Entity }): Entity?
	local weakest: Entity? = nil
	local weakest_difficulty = math.huge
	for _, other in present do
		local order = other.orders[1]
		if order ~= nil and order.kind == "attack" then
			continue
		end
		local difficulty = roster.difficulty_of(other.def_name)
		if
			difficulty < weakest_difficulty
			or (difficulty == weakest_difficulty and weakest ~= nil and other.id < weakest.id)
		then
			weakest = other
			weakest_difficulty = difficulty
		end
	end
	return weakest
end

-- The beacon `id` is gone. If it was destroyed, and not only cleared away with the map, that moves the game on a little,
-- which is small beside the units it will not make; and the last one standing brings their boss, at once, where it
-- stood.
local function lose(id: EntityId, record: Beacon)
	beacons[id] = nil
	if record.destroyed == false or switches.is_on "scavengers" == false then
		return
	end
	progress.set_progress(progress.progress() + settings.BEACON_KILL_PROGRESS)
	if count() == 0 then
		boss.summon(record.position)
	end
end

-- Makes one unit, or one defence, beside `beacon`. Units have no limit but the server's ceiling. When a beacon already
-- has all the defences it will take it makes room only by retiring one much easier than what it is about to make,
-- without a wreck. Without that, a ring filled early with the easiest things would leave everything unlocked later with
-- no way in.
local function spawn_at(beacon: Entity, record: Beacon, defense: boolean, tally: Tally)
	if defense == false and tally.units >= settings.UNIT_CEILING then
		return
	end
	local options, total = roster.spawn_options(defense, progress.budget(), record.sea, tally.enemy_air)
	if #options == 0 then
		return
	end
	local def_name = roster.weighted_pick(options, total, rng.stream "scavengers").def_name

	if defense then
		local present = defenses_around(beacon)
		if #present >= settings.MAX_DEFENSES_PER_BEACON then
			local weakest = weakest_of(present)
			if
				weakest == nil
				or roster.difficulty_of(weakest.def_name) * settings.UPGRADE_FACTOR > roster.difficulty_of(def_name)
			then
				return
			end
			deaths.destroy(weakest, "removed")
		end
	end

	make_near(def_name, beacon.position, if defense then DEFENSE_RING_START else UNIT_RING_START, tally)
end

-- Every beacon makes its units and defences as their clocks come round, once the game is far enough along. A beacon
-- that is gone is lost once it is forgotten (`forget`).
local function run(tally: Tally)
	local now = progress.now()
	for id, record in beacons do
		local beacon = state.get(id)
		if beacon == nil then
			continue
		end
		grow_beacon(beacon)
		-- nothing is made before the game has got far enough along, and a beacon that has been waiting for it starts the
		-- moment it does
		if record.eager == false and progress.progress() < settings.SPAWN_PROGRESS then
			continue
		end
		if now >= record.next_unit_at then
			record.next_unit_at = now + spawn_gap(settings.SPAWN_INTERVAL, record.sea)
			spawn_at(beacon, record, false, tally)
		end
		-- a beacon that has all the defences it will take just skips this: it never costs it a unit
		if now >= record.next_defense_at then
			record.next_defense_at = now + spawn_gap(settings.DEFENSE_SPAWN_INTERVAL, record.sea)
			spawn_at(beacon, record, true, tally)
		end
	end
end

-- Spends what the units that got nothing done were worth (units.luau) on units that can get across, at a beacon, as the
-- credit allows: one a second, each the hardest the budget allows being no more than the credit left, picked by weight
-- as the beacons pick. Credit short of anything that fits waits for more.
local function run_reroll(tally: Tally)
	local now = progress.now()
	if units.reroll_credit() <= 0 or now < next_reroll_at then
		return
	end
	next_reroll_at = now + REROLL_INTERVAL
	local at = standing()
	if #at == 0 or tally.units >= settings.UNIT_CEILING then
		return
	end
	local options, total = roster.crossing_options(math.min(progress.budget(), units.reroll_credit()), tally.enemy_air)
	if #options == 0 then
		return
	end
	local chosen = roster.weighted_pick(options, total, rng.stream "scavengers").def_name
	local beacon = at[rng.stream("scavengers"):NextInteger(1, #at)]
	if make_near(chosen, beacon.position, UNIT_RING_START, tally) then
		units.spend_credit(roster.difficulty_of(chosen))
	end
end

-- Once the beacons start making things, more come at random gaps, while fewer than the limit stand. The first of them,
-- and any with none standing, is always a land one, so a player never faces a threat they have no way to reach.
local function run_schedule()
	-- with their boss out it is the end, and no more come
	if boss.has_come() or progress.progress() < settings.SPAWN_PROGRESS then
		return
	end
	local now = progress.now()
	local due = next_beacon_at
	if due == nil then
		next_beacon_at = now + beacon_interval()
		return
	end
	if now < due then
		return
	end
	if count() >= settings.MAX_BEACONS or spawn_beacon(count() > 0) then
		next_beacon_at = now + beacon_interval()
	else
		next_beacon_at = now + BEACON_RETRY_DELAY
	end
end

-- The game's time is up: their boss comes, by a beacon if one stands, or in the middle of the map.
local function run_boss()
	if boss.has_come() or progress.progress() < 1 then
		return
	end
	local at = standing()
	boss.summon(if #at > 0 then at[rng.stream("scavengers"):NextInteger(1, #at)].position else Vector3.zero)
end

-- Puts a beacon down now, whatever the schedule says. Returns whether there was room.
local function summon_beacon(): boolean
	return spawn_beacon(count() > 0)
end

-- `entity` is leaving the map for `cause`: a beacon destroyed, and not only cleared away with the map, counts once it
-- is gone (`forget`).
local function note_destroyed(entity: Entity, cause: deaths.DeathCause)
	local record = beacons[entity.id]
	if record ~= nil and cause ~= "removed" then
		record.destroyed = true
	end
end

-- `id` is gone: a beacon is lost (`lose`).
local function forget(id: EntityId)
	local record = beacons[id]
	if record ~= nil then
		lose(id, record)
	end
end

-- When the next beacon goes up, if one is due.
local function next_beacon_in(): number?
	return if next_beacon_at ~= nil then math.max(next_beacon_at - progress.now(), 0) else nil
end

-- A new game on a new map: nothing of the last is remembered, and it opens again once a player stands.
local function reset()
	opened = false
	next_beacon_at = nil
	table.clear(beacons)
	next_reroll_at = 0
end

snapshot.keep("scavenger_beacons", function()
	return {
		opened = opened,
		next_beacon_at = next_beacon_at,
		beacons = beacons,
		next_reroll_at = next_reroll_at,
	}
end, function(saved)
	opened = saved.opened
	next_beacon_at = saved.next_beacon_at
	beacons = saved.beacons
	next_reroll_at = saved.next_reroll_at
end)

return table.freeze({
	open_once = open_once,
	run = run,
	run_schedule = run_schedule,
	run_boss = run_boss,
	run_reroll = run_reroll,
	standing = standing,
	summon_beacon = summon_beacon,
	force_beacon = force_beacon,
	count = count,
	next_beacon_in = next_beacon_in,
	enemy_air_exists = enemy_air_exists,
	note_destroyed = note_destroyed,
	forget = forget,
	reset = reset,
})
