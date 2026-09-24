-- Studio test runs. A Studio plugin - the Studio MCP's execute_luau, in the Edit datamodel - starts a Run session
-- with StudioTestService:ExecuteRunModeAsync(args). When `args.test` names one of the TESTS below, the session runs
-- that test instead of an ordinary game, and hands what it found back through StudioTestService:EndTest, which is
-- what ExecuteRunModeAsync returns. Nothing is set on or added to the place, and nothing has to be read back out of
-- the output, so a test leaves nothing behind:
--
--     local result = game:GetService("StudioTestService"):ExecuteRunModeAsync({ test = "bombing" })
--
-- `result` is a table: `ok`, and then either what the test found or `error`.
--
-- Any test can be run on another map than the usual by passing `preset`, a name from map_presets:
--
--     ExecuteRunModeAsync({ test = "map", preset = "rifted" })
--
-- A test owns the simulation's clock. The usual loop does not step it (see `owns_clock`); the test steps it itself,
-- a tick at a time and as fast as it can, so it sees every tick and runs the same way every time. Scavengers are
-- off, nobody joins a Run session, and the rocks and trees the map starts with are taken away unless the test is
-- started with `scenery = true`, so the world holds only what the test makes. The one exception is
-- "benchmark", which runs /benchmark as it is, on the usual loop, and hands back its report.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local passability = require(ReplicatedStorage.Shared.passability)
local starts = require(ReplicatedStorage.Shared.starts)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local map_state = require(ReplicatedStorage.Shared.map_state)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local shared_skins = require(ReplicatedStorage.Shared.skins)

local state = require(script.Parent.state)
local orders = require(script.Parent.orders)
local projectiles = require(script.Parent.projectiles)
local movement = require(script.Parent.movement)
local combat = require(script.Parent.combat)
local sight = require(script.Parent.sight)
local scavengers = require(script.Parent.scavengers)
local benchmark = require(script.Parent.benchmark)
local maps = require(script.Parent.maps)
local scenery = require(script.Parent.scenery)
local deformation = require(script.Parent.deformation)
local match = require(script.Parent.match)
local alliances = require(script.Parent.alliances)
local sharing = require(script.Parent.sharing)
local server_skins = require(script.Parent.skins)
local donuts = require(script.Parent.donuts)
local ai = require(script.Parent.ai)
local match_stats = require(script.Parent.match_stats)

type Entity = types.Entity
type TeamId = types.TeamId
type Findings = { [string]: any }

local OWN: TeamId = 1
local ENEMY: TeamId = 2
-- Health enough that nothing a test aims at dies before the test is over.
local UNKILLABLE = 1e7
-- The test yields to the engine every this many ticks, so that a long one is not taken for a script that hangs.
local YIELD_EVERY = 100
-- Bombs let go further apart than this, in seconds, are from different bursts.
local BURST_GAP = 1

-- The clock: the step to run, set when a test starts, and how many seconds of game it has run.
local step_simulation: ((number) -> ())? = nil
local sim_time = 0
local ticks_run = 0
local owning_clock = false

local function spawn(def_name: string, team: TeamId, x: number, z: number): Entity
	return state.create_entity(def_name, team, heightmap.ground_position(x, z), 0, "active")
end

local function unkillable(entity: Entity): Entity
	entity.health = UNKILLABLE
	entity.max_health = UNKILLABLE
	return entity
end

local function round(value: number, places: number): number
	local scale = 10 ^ places
	return math.round(value * scale) / scale
end

-- Runs the game on for `seconds`, calling `each` after every tick.
local function advance(seconds: number, each: (() -> ())?)
	local run_step = step_simulation :: (number) -> ()
	for _ = 1, math.round(seconds / config.TICK_DELTA) do
		run_step(config.TICK_DELTA)
		sim_time += config.TICK_DELTA
		ticks_run += 1
		if each ~= nil then
			each()
		end
		if ticks_run % YIELD_EVERY == 0 then
			task.wait()
		end
	end
end

-- Runs the game on until `entity` has no orders left, or for `seconds` at most, calling `each` after every tick,
-- and returns whether its orders ran out.
local function until_idle(entity: Entity, seconds: number, each: (() -> ())?): boolean
	local deadline = sim_time + seconds
	while sim_time < deadline do
		advance(config.TICK_DELTA, each)
		if #entity.orders == 0 then
			return true
		end
	end
	return false
end

-- How far the underside of `entity` is above the highest ground under any part of it, read at `samples` points
-- round its edge and under its middle: below zero, it is in the ground.
local function clearance(entity: Entity, samples: number): number
	local def = unit_defs.get(entity.def_name)
	local radius = unit_defs.collider_radius(def)
	local at = entity.position
	local ground = heightmap.height_at(at.X, at.Z)
	for index = 0, samples - 1 do
		local angle = index * (2 * math.pi / samples)
		ground = math.max(ground, heightmap.height_at(at.X + math.cos(angle) * radius, at.Z + math.sin(angle) * radius))
	end
	return at.Y - unit_defs.collider_height(def) / 2 - ground
end

-- A Whirlwind on an attack order against a building it cannot kill, for `args.seconds` (45 by default). For every
-- burst: how many bombs, how far apart in time they were let go, and where each came down along and across the
-- bomber's path, measured from the target (where it was last seen, within a tick of landing).
local function bombing(args: { [string]: any }): Findings
	local target = unkillable(spawn("solar_collector", ENEMY, 150, -60))
	local bomber = spawn("whirlwind", OWN, -60, -60)
	advance(config.TICK_DELTA)
	orders.issue(bomber, { { kind = "attack", target_id = target.id } }, false, false)

	type Bomb = { released: number, heading: Vector3, last: Vector3 }
	local bombs: { [number]: Bomb } = {}
	local order: { number } = {}
	advance(args.seconds or 45, function()
		for _, projectile in projectiles.in_flight() do
			if projectile.owner_id ~= bomber.id then
				continue
			end
			local bomb = bombs[projectile.id]
			if bomb == nil then
				local velocity = bomber.velocity
				bomb = {
					released = sim_time - projectile.flight.age,
					heading = Vector3.new(velocity.X, 0, velocity.Z).Unit,
					last = projectile.flight.position,
				}
				bombs[projectile.id] = bomb
				table.insert(order, projectile.id)
			end
			bomb.last = projectile.flight.position
		end
	end)

	local bursts = {}
	local burst: { [string]: any } = {}
	local previous: Bomb? = nil
	for _, id in order do
		local bomb = bombs[id]
		if previous ~= nil and bomb.released - previous.released <= BURST_GAP then
			table.insert(burst.gaps, round(bomb.released - previous.released, 4))
		else
			burst = { at = round(bomb.released, 2), gaps = {}, landed_along = {}, landed_across = {} }
			table.insert(bursts, burst)
		end
		local offset = Vector3.new(bomb.last.X - target.position.X, 0, bomb.last.Z - target.position.Z)
		local along = offset:Dot(bomb.heading)
		table.insert(burst.landed_along, round(along, 1))
		table.insert(burst.landed_across, round((offset - bomb.heading * along).Magnitude, 1))
		previous = bomb
	end
	return {
		bombs = #order,
		bursts = bursts,
		damage_to_target = round(UNKILLABLE - target.health, 0),
	}
end

-- A Valiant on an attack order against a Hercules it cannot kill, for `args.seconds` (30 by default). From ten
-- seconds in, once it has arrived: how slow it ever went, and how near and far from the Hercules it flew.
local function fighter(args: { [string]: any }): Findings
	local prey = unkillable(spawn("hercules", ENEMY, -100, 80))
	local plane = spawn("valiant", OWN, 40, 80)
	advance(config.TICK_DELTA)
	orders.issue(plane, { { kind = "attack", target_id = prey.id } }, false, false)

	local started = sim_time
	local slowest, nearest, furthest = math.huge, math.huge, 0
	advance(args.seconds or 30, function()
		if sim_time - started < 10 then
			return
		end
		local offset = prey.position - plane.position
		local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
		slowest = math.min(slowest, plane.velocity.Magnitude)
		nearest = math.min(nearest, distance)
		furthest = math.max(furthest, distance)
	end)
	return {
		slowest = round(slowest, 2),
		nearest = round(nearest, 1),
		furthest = round(furthest, 1),
		max_speed = round(unit_defs.get("valiant").max_speed :: number, 2),
		damage_to_prey = round(UNKILLABLE - prey.health, 0),
	}
end

-- An anti-air launcher, a Thistle or `args.launcher`, and an enemy bomber, a Whirlwind or `args.prey`, making bombing
-- runs over it for `args.seconds` (60 by default), both unkillable. Of the homing missiles it fires: how many hit, how
-- many times one flew past its target without hitting it (`overshoots`: its distance to the target stopped falling and
-- began to rise again, within OVERSHOOT_RANGE studs of it), how many came round through more than 120 degrees from the way they were launched to go back
-- for it (`circled_back`), and how long those that hit took to.
local OVERSHOOT_RANGE = 10
local function aa_missiles(args: { [string]: any }): Findings
	local launcher = unkillable(spawn(args.launcher or "thistle", OWN, 0, 0))
	local bait = unkillable(spawn("solar_collector", OWN, 30, 0))
	local prey = unkillable(spawn(args.prey or "whirlwind", ENEMY, -250, 40))
	advance(config.TICK_DELTA)
	orders.issue(prey, { { kind = "attack", target_id = bait.id } }, false, false)
	local prey_def = unit_defs.get(prey.def_name)
	local reach = unit_defs.collider_radius(prey_def) + unit_defs.collider_height(prey_def) / 2 + 1

	type Shot = {
		launched: number,
		first: Vector3,
		last: Vector3,
		speed: number,
		distance: number,
		closing: boolean,
		overshoots: number,
		turned: number,
	}
	local shots: { [number]: Shot } = {}
	local fired, hits, overshoots, circled, misses = 0, 0, 0, 0, 0
	local hit_times = {}
	local overshot_at = {}
	local function finish(shot: Shot)
		-- it was last seen a tick before it went off, so as far off as it flies in a tick is near enough
		if (shot.last - prey.position).Magnitude <= reach + shot.speed * config.TICK_DELTA then
			hits += 1
			table.insert(hit_times, sim_time - shot.launched)
		else
			misses += 1
		end
		overshoots += shot.overshoots
		if shot.turned > math.rad(120) then
			circled += 1
		end
	end
	advance(args.seconds or 60, function()
		local seen = {}
		for _, projectile in projectiles.in_flight() do
			if projectile.owner_id ~= launcher.id then
				continue
			end
			seen[projectile.id] = true
			local flight = projectile.flight
			local distance = (flight.position - prey.position).Magnitude
			local shot = shots[projectile.id]
			if shot == nil then
				fired += 1
				shot = {
					launched = sim_time - flight.age,
					first = flight.velocity.Unit,
					last = flight.position,
					speed = 0,
					distance = distance,
					closing = true,
					overshoots = 0,
					turned = 0,
				}
				shots[projectile.id] = shot
			end
			local closing = distance < shot.distance
			-- a missile that has only just left, and is still slow, can fall behind something quick going away from it for a
			-- moment; flying past it is only ever done close to it
			if shot.closing and not closing and shot.distance <= OVERSHOOT_RANGE then
				shot.overshoots += 1
				if #overshot_at < 20 then
					table.insert(overshot_at, `{round(shot.distance, 1)} studs off after {round(flight.age, 2)}s`)
				end
			end
			shot.closing = closing
			shot.distance = distance
			shot.last = flight.position
			shot.speed = flight.velocity.Magnitude
			shot.turned = math.max(shot.turned, math.acos(math.clamp(shot.first:Dot(flight.velocity.Unit), -1, 1)))
		end
		for id, shot in shots do
			if not seen[id] then
				finish(shot)
				shots[id] = nil
			end
		end
	end)
	local total = 0
	for _, t in hit_times do
		total += t
	end
	return {
		fired = fired,
		hits = hits,
		misses = misses,
		overshoots = overshoots,
		overshot_at = overshot_at,
		circled_back = circled,
		mean_time_to_hit = if #hit_times > 0 then round(total / #hit_times, 2) else nil,
		hits_by_damage = round(
			(UNKILLABLE - prey.health) / ((unit_defs.get(launcher.def_name).weapons :: any)[1].damage :: number),
			1
		),
	}
end

-- A Hephaestus sent to load a commander: once off the ledge above the low ground at the foot of the plateau, and
-- then at `args.slope_feet` (10 by default) spots at the foot of steep slopes, where the ground rises 5 to 12 studs
-- within 3.5. For each: whether it loaded, how long it took, how low it came while still more than 8 studs away
-- (it should be at its usual height), and how low it came at all once it had taken off (below zero is in the ground).
local function transport_pickup(args: { [string]: any }): Findings
	local function attempt(x: number, z: number, from_x: number): Findings
		local cargo = spawn("commander", OWN, x, z)
		local carrier = spawn("hephaestus", OWN, x + from_x, z)
		advance(config.TICK_DELTA)
		orders.issue(carrier, { { kind = "load", target_id = cargo.id } }, false, false)

		local started = sim_time
		local lowest_far, lowest = math.huge, math.huge
		local loaded = until_idle(carrier, 20, function()
			if sim_time - started < 3 then
				return
			end
			local height = clearance(carrier, 16)
			lowest = math.min(lowest, height)
			local offset = cargo.position - carrier.position
			if Vector3.new(offset.X, 0, offset.Z).Magnitude > 8 then
				lowest_far = math.min(lowest_far, height)
			end
		end) and #state.cargo_of(carrier.id) > 0
		local findings = {
			x = x,
			z = z,
			loaded = loaded,
			seconds = round(sim_time - started, 2),
			lowest_while_far = round(lowest_far, 2),
			lowest = round(lowest, 2),
		}
		state.mark_dead(carrier)
		state.mark_dead(cargo)
		advance(config.TICK_DELTA)
		return findings
	end

	local feet = {}
	local extent = math.min(heightmap.half_extents()) - 20
	for x = -extent, extent, 3 do
		-- the whole map is a lot of ground to read
		if x % 150 == 0 then
			task.wait()
		end
		for z = -extent, extent, 3 do
			local low = heightmap.height_at(x, z)
			if low <= config.WATER_LEVEL + 1 then
				continue
			end
			local rise = 0
			for index = 0, 7 do
				local angle = index * math.pi / 4
				rise = math.max(rise, heightmap.height_at(x + math.cos(angle) * 3.5, z + math.sin(angle) * 3.5) - low)
			end
			if rise > 5 and rise < 12 then
				table.insert(feet, { x = x, z = z, rise = round(rise, 1) })
			end
		end
	end

	local count = args.slope_feet or 10
	local at_feet = {}
	for index = 1, math.min(count, #feet) do
		local foot = feet[math.floor(index * #feet / (count + 1))]
		local findings = attempt(foot.x, foot.z, -40)
		findings.rise = foot.rise
		table.insert(at_feet, findings)
	end
	return {
		below_ledge = attempt(176, -120, -50),
		slope_feet = at_feet,
	}
end

-- A scavenger `args.unit` (a grunt by default) hunting a solar collector it cannot kill, for `args.seconds` (60 by
-- default) each time: once with the collector up on the plateau and the scavenger on the low ground below it, and
-- once on open ground. For each: how long it spent trying to go somewhere and getting nowhere (pushing into a cliff,
-- say), how near it got, how high it ended up compared with the collector, and whether it managed to shoot it.
local function scavenger_hunt(args: { [string]: any }): Findings
	local function attempt(target_x: number, target_z: number, from_x: number, from_z: number): Findings
		local target = unkillable(spawn("solar_collector", OWN, target_x, target_z))
		local hunter = spawn(args.unit or "grunt", config.SCAVENGER_TEAM, from_x, from_z)
		advance(config.TICK_DELTA)

		local stuck, travelled, nearest = 0, 0, math.huge
		local last = hunter.position
		advance(args.seconds or 60, function()
			local moved = (hunter.position - last).Magnitude
			last = hunter.position
			travelled += moved
			if movement.has_goal(hunter.id) and moved < 0.05 * config.TICK_DELTA then
				stuck += config.TICK_DELTA
			end
			local offset = target.position - hunter.position
			nearest = math.min(nearest, Vector3.new(offset.X, 0, offset.Z).Magnitude)
		end)
		local findings = {
			alive = hunter.alive,
			seconds_stuck = round(stuck, 2),
			travelled = round(travelled, 1),
			nearest = round(nearest, 1),
			height_below_target = round(target.position.Y - hunter.position.Y, 1),
			damage_to_target = round(UNKILLABLE - target.health, 0),
		}
		state.mark_dead(hunter)
		state.mark_dead(target)
		advance(config.TICK_DELTA)
		return findings
	end
	return {
		up_on_plateau = attempt(140, -120, 190, -120),
		open_ground = attempt(160, -40, 120, -40),
	}
end

-- The scavengers' opening. A commander in start box 1 and the gamemode on at progress 0: which start box the first
-- beacon went up in, and how many units they have after `args.wait` seconds (30 by default) still
-- short of the progress they start at. Then at that progress, how many after 12 seconds; and a grunt's wreck by the
-- beacon and another far from it, after long enough to come back: which of them did.
local function scavenger_opening(args: { [string]: any }): Findings
	local home = starts.default_spot(1)
	spawn("commander", OWN, home.X, home.Y)
	scavengers.set_progress(0)
	scavengers.set_enabled(true)
	advance(config.TICK_DELTA)

	local function scavengers_of(kind: string): { Entity }
		local found = {}
		for _, entity in state.all() do
			if entity.alive and entity.team == config.SCAVENGER_TEAM and entity.kind == kind then
				table.insert(found, entity)
			end
		end
		return found
	end

	local beacons = scavengers_of "building"
	local beacon = beacons[1]
	if beacon == nil then
		scavengers.set_enabled(false)
		return { beacons = 0 }
	end
	local box = 0
	for index = 1, starts.box_count() do
		if starts.in_box(index, beacon.position.X, beacon.position.Z) then
			box = index
			break
		end
	end

	advance(args.wait or 30)
	local units_before = #scavengers_of "unit"

	scavengers.set_progress(config.SCAVENGER_SPAWN_PROGRESS)
	advance(12)
	local units_after = #scavengers_of "unit"

	local function wreck_at(x: number, z: number): Entity
		local source = spawn("grunt", ENEMY, x, z)
		local wreck = state.create_wreck(source)
		state.mark_dead(source)
		return wreck
	end
	local toward_middle = -Vector3.new(beacon.position.X, 0, beacon.position.Z).Unit
	local near = wreck_at(beacon.position.X + toward_middle.X * 60, beacon.position.Z + toward_middle.Z * 60)
	local far_at = beacon.position + toward_middle * (config.SCAVENGER_REVIVE_RANGE + 150)
	local far = wreck_at(far_at.X, far_at.Z)
	advance(config.SCAVENGER_REVIVE_SECONDS + 2)
	scavengers.set_enabled(false)

	return {
		beacons = #beacons,
		boxes = starts.box_count(),
		beacon_box = box,
		units_before_progress = units_before,
		units_after_progress = units_after,
		near_wreck_revived = near.alive == false,
		far_wreck_revived = far.alive == false,
		far_wreck_progress = if far.wreck ~= nil then round(far.wreck.resurrect_progress, 1) else -1,
	}
end

-- Everything of the scavengers' that is alive and not a wreck, or only what is `def_name`.
local function scavenger_things(def_name: string?): { Entity }
	local found = {}
	for _, entity in state.all() do
		if
			entity.alive
			and entity.team == config.SCAVENGER_TEAM
			and entity.kind ~= "wreck"
			and (def_name == nil or entity.def_name == def_name)
		then
			table.insert(found, entity)
		end
	end
	return found
end

-- The end of a game against the scavengers, at the difficulty's `args.health` (5, brutal, by default) and progress
-- `args.progress` (0.3 by default). Their first beacon's health, grown with the progress, and a unit it makes, with the
-- difficulty's; then the beacon destroyed: how far the progress moved, whether that, the last beacon, brought their
-- boss, and its health. Then the boss destroyed: whether the game ended, and who won.
local function scavenger_endgame(args: { [string]: any }): Findings
	local health = args.health or 5
	local at_progress = args.progress or 0.3
	-- a team of its own, as a player has, so there is someone to win
	if state.get_team(OWN) == nil then
		state.create_team(OWN)
	end
	local home = starts.default_spot(1)
	unkillable(spawn("commander", OWN, home.X, home.Y))
	scavengers.set_health_multiplier(health)
	scavengers.set_progress(at_progress)
	scavengers.set_enabled(true)
	advance(config.TICK_DELTA)

	local beacon = scavenger_things("scavenger_beacon")[1]
	if beacon == nil then
		scavengers.set_enabled(false)
		return { beacon = false }
	end
	local beacon_health = beacon.max_health
	local beacon_expected = unit_defs.get("scavenger_beacon").health
		* (1 + config.SCAVENGER_BEACON_HEALTH_GROWTH * scavengers.progress())

	advance(config.SCAVENGER_SPAWN_INTERVAL + 1)
	local unit: Entity? = nil
	for _, entity in scavenger_things(nil) do
		if entity.kind == "unit" then
			unit = entity
			break
		end
	end

	local before = scavengers.progress()
	combat.apply_damage(beacon, beacon.health + 1)
	advance(config.TICK_DELTA * 2)
	local after = scavengers.progress()
	local boss = scavenger_things("scavenger_boss")[1]

	local findings: Findings = {
		beacon_health = round(beacon_health, 0),
		beacon_health_expected = round(beacon_expected, 0),
		unit = if unit ~= nil then unit.def_name else "none",
		unit_health_multiple = if unit ~= nil
			then round(unit.max_health / unit_defs.get(unit.def_name).health, 2)
			else -1,
		progress_moved = round(after - before, 4),
		boss_came = boss ~= nil,
	}
	if boss == nil then
		scavengers.set_enabled(false)
		return findings
	end
	findings.boss_health_multiple = round(boss.max_health / unit_defs.get("scavenger_boss").health, 2)
	findings.phase_before_boss_dies = game_phase.phase()

	combat.apply_damage(boss, boss.health + 1)
	advance(config.TICK_DELTA * 2)
	findings.phase = game_phase.phase()
	findings.winners = table.concat(game_phase.winners(), ",")
	findings.end_reason = game_phase.end_reason() or ""
	scavengers.set_enabled(false)
	return findings
end

-- Scavengers that can get nowhere, best on `preset = "islands"`: `args.count` grunts (2 by default) on the island of
-- start 3 with the only thing of a player's a commander on the island of start 1, which they cannot kill. After
-- `args.seconds` (130 by default), past `SCAVENGER_FUTILE_SECONDS`: whether the grunts were taken away, and without
-- wrecks, and what they left to be rerolled.
-- Then with the gamemode on and a beacon by it: what that credit was spent on, and whether each can get across.
local function scavenger_stranded(args: { [string]: any }): Findings
	local home = starts.center(1)
	local away = starts.center(3)
	unkillable(spawn("commander", OWN, home.X, home.Y))
	local grunt_ids = {}
	for index = 1, args.count or 2 do
		table.insert(grunt_ids, spawn("grunt", config.SCAVENGER_TEAM, away.X + index * 4, away.Y).id)
	end
	scavengers.set_progress(0.5)
	advance(args.seconds or 130)

	local wrecks = 0
	for _, entity in state.all() do
		if entity.alive and entity.kind == "wreck" then
			wrecks += 1
		end
	end
	local credit = scavengers.pending_reroll()
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
	scavengers.set_enabled(true)
	scavengers.force_beacon(away.X + 30, away.Y)
	advance(3)
	local made = {}
	for _, entity in scavenger_things(nil) do
		if before[entity.id] == nil and entity.kind == "unit" then
			local def = unit_defs.get(entity.def_name)
			local crosses = def.air ~= nil or unit_defs.tolerates_water(def, 0, 400)
			table.insert(made, `{entity.def_name}{if crosses then "" else " (cannot cross)"}`)
		end
	end
	scavengers.set_enabled(false)
	findings.made_after = table.concat(made, ", ")
	findings.credit_after = round(scavengers.pending_reroll(), 2)
	return findings
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
			task.wait()
		end
		for z = -extent, extent, 8 do
			if accept(x, z) then
				return Vector3.new(x, 0, z)
			end
		end
	end
	return nil
end

-- Makes something ready where it rests at (x, z): on the ground, on the water or under it, as it would stand there.
local function spawn_resting(def_name: string, team: TeamId, x: number, z: number): Entity
	local def = unit_defs.get(def_name)
	local y = unit_defs.surface_height(def, x, z) + unit_defs.collider_height(def) / 2
	return state.create_entity(def_name, team, Vector3.new(x, y, z), 0, "active")
end

-- A match of `seconds` of a `shooter_def` at `shooter_at` against a `target_def` at `target_at` that it cannot kill,
-- each resting where it is: how much damage the target took, how many projectiles and how many torpedoes the shooter
-- let go, and how far the target's top and bottom are from the water's surface.
local function water_duel(
	shooter_def: string,
	target_def: string,
	target_at: Vector3,
	shooter_at: Vector3,
	seconds: number
): Findings
	local target = unkillable(spawn_resting(target_def, ENEMY, target_at.X, target_at.Z))
	-- the target may shoot back, and the shooter has to last the whole match for its count of shots to mean anything
	local shooter = unkillable(spawn_resting(shooter_def, OWN, shooter_at.X, shooter_at.Z))
	local seen: { [number]: boolean } = {}
	local shots, torpedoes = 0, 0
	advance(seconds, function()
		for _, projectile in projectiles.in_flight() do
			if projectile.owner_id == shooter.id and seen[projectile.id] == nil then
				seen[projectile.id] = true
				shots += 1
				if projectile.params.torpedo == true then
					torpedoes += 1
				end
			end
		end
	end)
	local half = unit_defs.collider_height(unit_defs.get(target_def)) / 2
	local findings = {
		damage_to_target = round(UNKILLABLE - target.health, 0),
		shots = shots,
		torpedoes = torpedoes,
		target_top_above_water = round(target.position.Y + half - config.WATER_LEVEL, 2),
		target_bottom_above_water = round(target.position.Y - half - config.WATER_LEVEL, 2),
	}
	state.mark_dead(shooter)
	state.mark_dead(target)
	advance(config.TICK_DELTA)
	return findings
end

-- Submarines and torpedoes. Several matches, each `args.seconds` (15 by default) long, of a shooter against
-- something at `distance` that it cannot kill, all out in deep water unless they are said to be on land: how much
-- damage the target took, how many projectiles and how many torpedoes the shooter let go, and how far the target's
-- top and bottom are from the water's surface. Nothing but a torpedo should be aimed at a submarine or at
-- anything else wholly under the water, a torpedo at nothing that is not in the water, and nothing but a torpedo
-- should be fired from under the water.
local function naval(args: { [string]: any }): Findings
	local seconds = args.seconds or 15
	local sea = find_spot(function(x: number, z: number): boolean
		return deep_all_round(x, z, 8, 70)
	end)
	assert(sea ~= nil, "no open deep water on this map")
	-- dry land with deep open water 30 studs off it, one way or another
	local shore_offset = Vector3.zero
	local shore = find_spot(function(x: number, z: number): boolean
		if heightmap.height_at(x, z) < config.WATER_LEVEL + 1 then
			return false
		end
		for index = 0, 7 do
			local angle = index * math.pi / 4
			local offset = Vector3.new(math.cos(angle) * 30, 0, math.sin(angle) * 30)
			if deep_all_round(x + offset.X, z + offset.Z, 6, 8) then
				shore_offset = offset
				return true
			end
		end
		return false
	end)

	local function duel(shooter_def: string, target_def: string, target_at: Vector3, shooter_at: Vector3): Findings
		return water_duel(shooter_def, target_def, target_at, shooter_at, seconds)
	end

	local sea_spot = sea :: Vector3
	local off = Vector3.new(30, 0, 0)
	local findings: Findings = {
		sea = { x = sea_spot.X, z = sea_spot.Z, depth = round(heightmap.water_depth(sea_spot.X, sea_spot.Z), 1) },
		buccaneer_at_orca = duel("buccaneer", "orca", sea_spot, sea_spot + off),
		orca_at_buccaneer = duel("orca", "buccaneer", sea_spot, sea_spot + off),
		riptide_at_orca = duel("riptide", "orca", sea_spot, sea_spot + off),
		orca_at_commander_on_sea_floor = duel("orca", "commander", sea_spot, sea_spot + off),
		riptide_at_commander_on_sea_floor = duel("riptide", "commander", sea_spot, sea_spot + off),
		commander_on_sea_floor_at_riptide = duel("commander", "riptide", sea_spot, sea_spot + off),
	}
	if shore ~= nil then
		local land = shore :: Vector3
		findings.orca_at_commander_on_land = duel("orca", "commander", land, land + shore_offset)
	end
	return findings
end

-- Hovercraft. A Goon, or `args.unit`, is sent from dry land down a beach out onto deep water and back, and then out
-- to open sea, and must get there every time, riding the water's surface all the way and taking no harm from it.
-- Then matches as `naval` has them, each `args.seconds` (15 by default) long, out in deep water: an Orca's torpedoes
-- must never be aimed at a hovercraft, a Buccaneer's depth charges neither, while its laser hurts one, and a Halberd
-- must be able to shoot a ship. The lasers spend energy a shot, which a team in a test has none of, so the matches
-- are played with nocost on.
local function hovercraft(args: { [string]: any }): Findings
	local seconds = args.seconds or 15
	local sea = find_spot(function(x: number, z: number): boolean
		return deep_all_round(x, z, 8, 70)
	end)
	assert(sea ~= nil, "no open deep water on this map")
	local sea_spot = sea :: Vector3
	local traveller = args.unit or "goon"
	local def = unit_defs.get(traveller)
	-- dry land from which a straight run of ground not too steep for it goes down a beach into deep water, where
	-- `beach_end` is
	local beach_end = Vector3.zero
	local shore = find_spot(function(x: number, z: number): boolean
		if
			heightmap.height_at(x, z) < config.WATER_LEVEL + 1
			or passability.passable_at(def.slope_class, x, z) == false
		then
			return false
		end
		for index = 0, 7 do
			local angle = index * math.pi / 4
			local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
			for distance = 2, 60, 2 do
				local point = Vector3.new(x, 0, z) + direction * distance
				if passability.passable_at(def.slope_class, point.X, point.Z) == false then
					break
				end
				if heightmap.water_depth(point.X, point.Z) >= 6 then
					beach_end = point + direction * 10
					return true
				end
			end
		end
		return false
	end)
	assert(shore ~= nil, "no beach a hovercraft can climb")
	local land = shore :: Vector3
	local goon = unkillable(spawn_resting(traveller, OWN, land.X, land.Z))
	advance(config.TICK_DELTA)
	local function go(to: Vector3): Findings
		local destination = unit_defs.surface_position(def, to.X, to.Z)
		local route, searched = pathfinder.route(def, goon.position, destination, 8000)
		orders.issue(goon, route, false, false)
		local started = sim_time
		-- how low its underside came over the water, and how far from the surface it ever was there
		local lowest_over_water = math.huge
		local off_surface = 0
		local arrived = until_idle(goon, args.travel_seconds or 90, function()
			local at = goon.position
			if heightmap.water_depth(at.X, at.Z) > 0 then
				local bottom = at.Y - unit_defs.collider_height(def) / 2
				lowest_over_water = math.min(lowest_over_water, bottom - config.WATER_LEVEL)
				off_surface = math.max(off_surface, math.abs(bottom - unit_defs.surface_height(def, at.X, at.Z)))
			end
		end)
		local offset = destination - goon.position
		return {
			passable_from = passability.passable_at(def.slope_class, goon.position.X, goon.position.Z),
			passable_to = passability.passable_at(def.slope_class, to.X, to.Z),
			searched = searched,
			waypoints = #route,
			arrived = arrived,
			seconds = round(sim_time - started, 2),
			left_to_go = round(Vector3.new(offset.X, 0, offset.Z).Magnitude, 1),
			lowest_over_water = if lowest_over_water == math.huge
				then "never over water"
				else round(lowest_over_water, 2),
			off_surface = round(off_surface, 3),
			in_water = unit_defs.in_water(def, goon.position),
			submerged = unit_defs.submerged(def, goon.position),
		}
	end
	local findings: Findings = {
		sea = { x = sea_spot.X, z = sea_spot.Z, depth = round(heightmap.water_depth(sea_spot.X, sea_spot.Z), 1) },
		land = { x = land.X, z = land.Z, height = round(heightmap.height_at(land.X, land.Z), 1) },
		beach_end = {
			x = beach_end.X,
			z = beach_end.Z,
			depth = round(heightmap.water_depth(beach_end.X, beach_end.Z), 1),
		},
		off_the_beach = go(beach_end),
		back_ashore = go(land),
		out_to_open_sea = go(sea_spot),
	}
	findings.goon_damage_from_travel = round(UNKILLABLE - goon.health, 0)
	state.mark_dead(goon)
	advance(config.TICK_DELTA)

	local nocost = require(script.Parent.nocost)
	nocost.set(true)
	local off = Vector3.new(30, 0, 0)
	findings.orca_at_goon = water_duel("orca", "goon", sea_spot, sea_spot + off, seconds)
	findings.buccaneer_at_halberd = water_duel("buccaneer", "halberd", sea_spot, sea_spot + off, seconds)
	-- inside the Halberd's reach, 300 elmos
	findings.halberd_at_riptide = water_duel("halberd", "riptide", sea_spot, sea_spot + Vector3.new(20, 0, 0), seconds)
	findings.orca_at_riptide = water_duel("orca", "riptide", sea_spot, sea_spot + off, seconds)
	nocost.set(false)
	return findings
end

-- A `args.shooter` (a Pulsar by default) against a commander it cannot kill, `args.distance` (60 by default) away on
-- open ground, until its first beam has gone out: the damage the commander took on each tick from the first shot on,
-- which should come as the weapon's damage split evenly over its beam's time, a slice a tick.
local function beam(args: { [string]: any }): Findings
	local shooter_def = args.shooter or "pulsar"
	local target = unkillable(spawn_resting("commander", ENEMY, 0, 0))
	spawn_resting(shooter_def, OWN, args.distance or 60, 0)
	local weapon = (unit_defs.get(shooter_def).weapons :: { types.Weapon })[1]
	local per_tick = {}
	local last = target.health
	local started = false
	advance(weapon.reload + 5, function()
		local took = last - target.health
		last = target.health
		if took > 0 then
			started = true
		end
		if started and #per_tick * config.TICK_DELTA < (weapon.beam_time or 0) + 0.5 then
			table.insert(per_tick, round(took, 1))
		end
	end)
	return {
		damage = weapon.damage,
		beam_time = weapon.beam_time,
		damage_per_tick = per_tick,
	}
end

-- Each laser tower in turn (or just `args.def`), on the same spot, with an unkillable, unarmed Construction Bot straight
-- behind it at 60% of its first weapon's range, run for `args.seconds` (3 by default). For each weapon with a turret:
-- how long it took to fire its first shot, how long a half turn takes at its turn rate, and where it pointed when it
-- fired (pi or -pi is straight behind). Then the pop-up state machine on its own, for a pop-up that takes 10 ticks
-- to open and 6 to close and lingers 20: the tick it enters each state, with something to shoot for its first 15
-- ticks, then nothing, then something again 4 ticks into closing.
local function turret(args: { [string]: any }): Findings
	local turrets = require(script.Parent.turrets)
	local findings: Findings = {}

	-- lasers are paid for in energy, so the tower's team has to exist
	if state.get_team(OWN) == nil then
		state.create_team(OWN)
	end
	local def_names = if typeof(args.def) == "string" then { args.def } else { "guard", "twin_guard", "warden" }
	for _, def_name in def_names do
		-- every tower in turn on the same spot, which is dry land, cleared between them
		local x = 0
		local tower = unkillable(spawn_resting(def_name, OWN, x, 0))
		local weapons = unit_defs.get(def_name).weapons :: { types.Weapon }
		local behind = unkillable(spawn_resting("construction_bot", ENEMY, x, -weapons[1].range * 0.6))

		local started = sim_time
		local first_shot: { [number]: number } = {}
		local aim_at_shot: { [number]: number } = {}
		local reloads: { [number]: number } = {}
		advance(args.seconds or 3, function()
			for index in weapons do
				local reload = tower.weapon_reloads[index] or 0
				-- a reload that jumps up is a shot just fired
				if first_shot[index] == nil and reload > (reloads[index] or 0) + 1e-6 then
					first_shot[index] = round(sim_time - started, 2)
					aim_at_shot[index] = round(tower.weapon_aims[index] or 0, 3)
				end
				reloads[index] = reload
			end
		end)

		local report = {}
		for index, weapon in weapons do
			local turn = weapon.turret
			table.insert(report, {
				first_shot = first_shot[index] or "never",
				half_turn = if turn ~= nil then round(math.pi / turn.turn_rate, 2) else "no turret",
				aim_at_shot = aim_at_shot[index],
				final_aim = round(tower.weapon_aims[index] or 0, 3),
			})
		end
		local team = state.get_team(OWN)
		table.insert(report, {
			energy = if team ~= nil then round(team.energy, 0) else "no team",
			target_health_lost = round(UNKILLABLE - behind.health, 0),
			distance = round((behind.position - tower.position).Magnitude, 1),
			range = round(weapons[1].range, 1),
		})
		findings[def_name] = report
		state.mark_dead(behind)
		state.mark_dead(tower)
		advance(config.TICK_DELTA)
	end

	local popup = { open_ticks = 10, close_ticks = 6, linger_ticks = 20 }
	local entity = { animation = { state = "closed", ticks = 0 } } :: any
	local entered: { string } = {}
	local last = entity.animation.state
	local closing_since: number? = nil
	for tick = 1, 80 do
		local wants = tick <= 15 or (closing_since ~= nil and tick >= closing_since + 4)
		local open = turrets.advance(entity, popup, wants)
		local now = entity.animation.state
		if now ~= last then
			table.insert(entered, `{tick}:{now}{if open then " (fires)" else ""}`)
			if now == "closing" and closing_since == nil then
				closing_since = tick
			end
			last = now
		end
	end
	findings.popup = table.concat(entered, ", ")
	return findings
end

-- A Bot Lab, or `args.lab`, turned each quarter in turn, making two Grunts, or `args.unit`s, at no cost. For each: where the
-- blueprint went down, in studs to the lab's right and out through its doorway, and which way it faced; which way the
-- first unit drove while it was getting out and how long that took, with a move back through the lab given to it
-- half way out, the way a player's would be; how deep it ever was in the lab once it was out, as that move takes it
-- round; and how long after the first unit was out the second blueprint went down.
local function lab_exit(args: { [string]: any }): Findings
	local production = require(script.Parent.production)
	local geometry = require(ReplicatedStorage.Shared.geometry)
	local placement = require(script.Parent.placement)
	local nocost = require(script.Parent.nocost)
	local lab_name = args.lab or "bot_lab"
	local unit_name = args.unit or "grunt"
	local findings: Findings = {}

	-- what a unit costs is beside the point: it is finished the moment the lab starts it
	nocost.set(true)
	for quarter = 0, 3 do
		local facing = quarter * math.pi / 2
		local lab_def = unit_defs.get(lab_name)
		local y = unit_defs.surface_height(lab_def, 0, 0) + unit_defs.collider_height(lab_def) / 2
		local lab = unkillable(state.create_entity(lab_name, OWN, Vector3.new(0, y, 0), facing, "active"))
		state.flush()
		local out = Vector3.new(math.sin(facing), 0, math.cos(facing))
		local right = Vector3.new(-out.Z, 0, out.X)
		local function local_of(position: Vector3): { number }
			local offset = geometry.flatten(position - lab.position)
			return { round(offset:Dot(right), 2), round(offset:Dot(out), 2) }
		end
		local function penetration(unit: Entity): number
			local a = placement.half_extents_for(unit)
			local b = placement.half_extents_for(lab)
			local dx = a.X + b.X - math.abs(unit.position.X - lab.position.X)
			local dz = a.Y + b.Y - math.abs(unit.position.Z - lab.position.Z)
			return math.max(0, math.min(dx, dz))
		end

		production.enqueue(lab, unit_name)
		production.enqueue(lab, unit_name)
		local report: Findings = {}

		-- the first blueprint
		local first: Entity? = nil
		local second_placed: number? = nil
		local function watch()
			local id = production.current_blueprint(lab.id)
			if id == nil then
				return
			end
			if first == nil then
				first = state.get(id)
				report.blueprint_at = local_of((first :: Entity).position)
			elseif second_placed == nil and id ~= (first :: Entity).id then
				second_placed = sim_time
			end
		end
		advance(1, watch)
		local unit = first :: Entity
		report.blueprint_facing_out = round(math.cos(unit.facing - math.atan2(out.X, out.Z)), 3)

		local deadline = sim_time + 60
		while unit.state == "blueprint" and sim_time < deadline do
			advance(config.TICK_DELTA, watch)
		end
		-- the tick after it is finished, the lab sends it out
		advance(config.TICK_DELTA)
		report.exiting = movement.exiting_from(unit.id) == lab.id
		local began = sim_time
		local start = unit.position
		local told = false
		local behind = lab.position - out * 40
		while movement.exiting_from(unit.id) ~= nil and sim_time < began + 20 do
			advance(config.TICK_DELTA, watch)
			if told == false and geometry.flatten(unit.position - lab.position):Dot(out) > 0 then
				told = true
				unit.orders = { { kind = "move", position = behind, target_id = nil } }
			end
		end
		report.exit_seconds = round(sim_time - began, 2)
		report.exit_direction_out = round(geometry.flatten(unit.position - start).Unit:Dot(out), 3)
		report.released_at = local_of(unit.position)
		report.order_kept = #unit.orders > 0 and unit.orders[#unit.orders].position == behind

		local released = sim_time
		-- behind it, a unit the lab did not make, sent the same way through it, for how deep the lab lets anything in
		local control = spawn_resting(unit_name, OWN, unit.position.X + out.X * 8, unit.position.Z + out.Z * 8)
		control.orders = { { kind = "move", position = behind, target_id = nil } }
		local deepest = 0
		local control_deepest = 0
		advance(args.seconds or 12, function()
			deepest = math.max(deepest, penetration(unit))
			control_deepest = math.max(control_deepest, penetration(control))
			watch()
		end)
		report.deepest_in_lab_after = round(deepest, 2)
		report.control_deepest_in_lab = round(control_deepest, 2)
		report.ended_at = local_of(unit.position)
		report.second_blueprint_after = if second_placed ~= nil then round(second_placed - released, 2) else "never"
		findings[`facing_{quarter}`] = report

		for _, entity in state.all() do
			state.mark_dead(entity)
		end
		advance(config.TICK_DELTA)
	end
	nocost.set(false)
	return findings
end

-- Orders given to a lab, the way `commands` gives them: they stay in the lab's own queue, which the lab never
-- carries out, and each unit it makes takes a copy of them once it is out.
local function lab_orders(args: { [string]: any }): Findings
	local production = require(script.Parent.production)
	local geometry = require(ReplicatedStorage.Shared.geometry)
	local nocost = require(script.Parent.nocost)
	local lab_name = args.lab or "bot_lab"
	local unit_name = args.unit or "grunt"
	local findings: Findings = {}

	nocost.set(true)
	local lab_def = unit_defs.get(lab_name)
	local y = unit_defs.surface_height(lab_def, 0, 0) + unit_defs.collider_height(lab_def) / 2
	local lab = unkillable(state.create_entity(lab_name, OWN, Vector3.new(0, y, 0), 0, "active"))
	state.flush()
	local first_stop = heightmap.ground_position(20, 40)
	local last_stop = heightmap.ground_position(-20, 60)
	orders.issue(lab, { { kind = "move", position = first_stop, target_id = nil } }, false, false)
	orders.issue(lab, { { kind = "move", position = last_stop, target_id = nil } }, true, false)
	local lab_at = lab.position

	production.enqueue(lab, unit_name)
	local unit: Entity? = nil
	local deadline = sim_time + 60
	while unit == nil and sim_time < deadline do
		advance(config.TICK_DELTA)
		local id = production.current_blueprint(lab.id)
		if id ~= nil then
			unit = state.get(id)
		end
	end
	local made = unit :: Entity
	-- the most orders it was carrying at once, and where the last of them was, seen every tick
	local most_orders = 0
	local ends_at_last_stop = false
	local function watch()
		if #made.orders > most_orders then
			most_orders = #made.orders
			local last = made.orders[#made.orders]
			ends_at_last_stop = last.position ~= nil and geometry.distance_2d(last.position, last_stop) < 1
		end
	end
	while made.state == "blueprint" and sim_time < deadline do
		advance(config.TICK_DELTA, watch)
	end
	advance(config.TICK_DELTA, watch)
	findings.arrived = until_idle(made, args.seconds or 40, watch)
	findings.unit_most_orders = most_orders
	findings.unit_last_order_is_last_stop = ends_at_last_stop
	findings.unit_distance_to_last_stop = round(geometry.distance_2d(made.position, last_stop), 2)
	findings.lab_orders_kept = #lab.orders
	findings.lab_moved = round(geometry.distance_2d(lab.position, lab_at), 3)

	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	advance(config.TICK_DELTA)
	nocost.set(false)
	return findings
end

-- `order` for `entity` with its way laid ahead of it the way a player's is: the client works out the waypoints
-- (`pathfinder.waypoints_to`) and the server checks them (`commands.with_route`). Also how many waypoints were sent.
local function player_route(entity: Entity, order: types.Order): ({ types.Order }, number)
	local commands = require(script.Parent.commands)
	local def = unit_defs.get(entity.def_name)
	local destination = order.position
	if order.target_id ~= nil then
		local target = state.get(order.target_id)
		destination = if target ~= nil then target.position else destination
	end
	if destination == nil then
		return { order }, 0
	end
	local reach = unit_defs.order_reach(def, order.kind) + (order.radius or 0)
	local waypoints = pathfinder.waypoints_to(def, entity.position, destination, reach, 8000)
	return commands.with_route(entity, order, waypoints), #waypoints
end

-- Planes on wings, Whirlwinds and Valiants (or just `args.unit`), sent at the edge of the map every way they can be:
-- just inside every side and corner, each is told to fly into the edge, to turn back for a point just behind it (which
-- has it fly on straight into the edge first, to get room to turn), to fly along the edge, to attack something at the
-- edge (a bombing run for a Whirlwind, a transport flying to the edge for a Valiant), to fight its way to the edge,
-- and to fly a chain of moves from one point on the edge to the next. Best run with `preset = "hooked"`, whose map is
-- small enough that fights often come to its edge. They all fly at once for `args.seconds` (30 by default); aircraft do
-- not run into each other. Once `args.warmup` seconds (3) have passed for them to take off and get up to speed, a plane
-- is slow while, with orders left, it has covered less than a quarter of what it would at full speed over the last
-- second; one that stays slow for more than `args.stuck_seconds` (1) is `stuck`. A plane that turns hard round against
-- the edge is slow for a moment, but never for that long. One that stays within EDGE_TOUCH studs of the edge for more
-- than `args.edge_seconds`, or while it has orders for longer than it takes it to turn right round and half a second
-- more, is `pinned_to_edge`. One that has landed on the edge with nothing to do is neither. A plane that has landed
-- right on the edge facing off the map is also sent back to the middle (`takeoff_from_edge`). Every plane that was either, what it was told, where and for how
-- long; any plane that left the map; and the longest any plane was slow, and on the edge, whether or not too long.
-- `args.trace` follows one plane (see below).
local EDGE_TOUCH = 0.5
local function wing_edges(args: { [string]: any }): Findings
	local hx, hz = heightmap.half_extents()
	local margin = args.margin or 4
	local units = if typeof(args.unit) == "string" then { args.unit } else { "whirlwind", "valiant" }

	local function spawn_facing(def_name: string, team: TeamId, at: Vector3, toward: Vector3): Entity
		local ground = heightmap.ground_position(at.X, at.Z)
		return state.create_entity(def_name, team, ground, math.atan2(toward.X, toward.Z), "active")
	end
	local function inside(point: Vector3): Vector3
		return Vector3.new(
			math.clamp(point.X, -hx + margin, hx - margin),
			0,
			math.clamp(point.Z, -hz + margin, hz - margin)
		)
	end

	type Case = {
		plane: Entity,
		name: string,
		samples: { Vector3 },
		stuck_for: number,
		worst: number,
		at: Vector3?,
		from: Vector3?,
		speed: number,
		on_edge_for: number,
		longest_on_edge: number,
		left_map: boolean,
	}
	local cases: { Case } = {}
	local pending: { () -> () } = {}
	for _, unit in units do
		for sx = -1, 1 do
			for sz = -1, 1 do
				if sx == 0 and sz == 0 then
					continue
				end
				local edge = inside(Vector3.new(sx * hx, 0, sz * hz))
				local inward = -Vector3.new(sx, 0, sz).Unit
				local along = Vector3.new(-inward.Z, 0, inward.X)
				local where = `{unit} at ({sx},{sz})`
				local function add(name: string, from: Vector3, toward: Vector3, give: (Entity) -> ())
					local plane = spawn_facing(unit, OWN, inside(from), toward)
					table.insert(cases, {
						plane = plane,
						name = `{name}, {where}`,
						samples = {},
						stuck_for = 0,
						worst = 0,
						at = nil,
						from = nil,
						speed = 0,
						on_edge_for = 0,
						longest_on_edge = 0,
						left_map = false,
					})
					table.insert(pending, function()
						give(plane)
					end)
				end
				local function move_to(point: Vector3): types.Order
					return { kind = "move", position = heightmap.ground_position(point.X, point.Z), target_id = nil }
				end

				add("into_edge", edge + inward * 40, -inward, function(plane)
					orders.issue(plane, { move_to(edge) }, false, false)
				end)
				add("turn_back", edge + inward * 25, -inward, function(plane)
					orders.issue(plane, { move_to(inside(edge + inward * 45)) }, false, false)
				end)
				add("along_edge", edge, along, function(plane)
					orders.issue(plane, { move_to(inside(edge + along * 1000)) }, false, false)
				end)
				add("fight_edge", edge + inward * 40, -inward, function(plane)
					orders.issue(
						plane,
						{ { kind = "fight", position = heightmap.ground_position(edge.X, edge.Z) } },
						false,
						false
					)
				end)
				add("queued", edge + along * 30, -along, function(plane)
					orders.issue(plane, {
						move_to(inside(edge - along * 30)),
						move_to(inside(edge + along * 30)),
						move_to(edge),
						move_to(inside(edge - along * 60)),
					}, false, false)
				end)
				-- landed right on the edge, facing off the map, and sent back to the middle
				local brink = Vector3.new(math.clamp(sx * hx, -hx, hx), 0, math.clamp(sz * hz, -hz, hz))
				local landed = spawn_facing(unit, OWN, brink, -inward)
				table.insert(cases, {
					plane = landed,
					name = `takeoff_from_edge, {where}`,
					samples = {},
					stuck_for = 0,
					worst = 0,
					at = nil,
					from = nil,
					speed = 0,
					on_edge_for = 0,
					longest_on_edge = 0,
					left_map = false,
				})
				table.insert(pending, function()
					orders.issue(landed, { move_to(Vector3.zero) }, false, false)
				end)
				if unit == "whirlwind" then
					local target = unkillable(spawn("solar_collector", ENEMY, edge.X, edge.Z))
					add("attack_edge", edge + inward * 60, -inward, function(plane)
						orders.issue(plane, { { kind = "attack", target_id = target.id } }, false, false)
					end)
				else
					local prey = unkillable(spawn_facing("hercules", ENEMY, edge + inward * 50, -inward))
					table.insert(pending, function()
						orders.issue(prey, { move_to(edge) }, false, false)
					end)
					add("attack_edge", edge + inward * 70, -inward, function(plane)
						orders.issue(plane, { { kind = "attack", target_id = prey.id } }, false, false)
					end)
				end
			end
		end
	end
	advance(config.TICK_DELTA)
	for _, give in pending do
		give()
	end

	local per_second = math.round(1 / config.TICK_DELTA)
	-- they start on the ground, and are slow until they have taken off and got up to speed
	local warmup = args.warmup or 3
	local started = sim_time
	-- `args.trace` names a case (as it is reported, like "attack_edge, valiant at (1,1)"): where that plane is, where it
	-- heads, and what its order is aimed at, every quarter second, for working out what it does
	local traced: Case? = nil
	for _, case in cases do
		if case.name == args.trace then
			traced = case
		end
	end
	local trace = {}
	local ticks = 0
	advance(args.seconds or 30, function()
		ticks += 1
		if traced ~= nil and ticks % math.max(1, math.round(0.25 / config.TICK_DELTA)) == 0 then
			local plane = traced.plane
			local order = plane.orders[1]
			local aim = if order == nil
				then nil
				elseif order.target_id ~= nil then (state.get(order.target_id) or plane).position
				else order.position
			table.insert(
				trace,
				`{round(sim_time - started, 2)}: at ({round(plane.position.X, 1)}, {round(plane.position.Z, 1)})`
					.. ` facing {round(math.deg(plane.facing) % 360, 0)} speed {round(plane.velocity.Magnitude, 1)}`
					.. (if aim ~= nil then ` aim ({round(aim.X, 1)}, {round(aim.Z, 1)})` else " no order")
			)
		end
		if sim_time - started < warmup then
			return
		end
		for _, case in cases do
			local plane = case.plane
			local at = plane.position
			if not heightmap.in_bounds(at.X, at.Z) then
				case.left_map = true
			end
			if #plane.orders > 0 and (math.abs(at.X) >= hx - EDGE_TOUCH or math.abs(at.Z) >= hz - EDGE_TOUCH) then
				case.on_edge_for += config.TICK_DELTA
				case.longest_on_edge = math.max(case.longest_on_edge, case.on_edge_for)
			else
				case.on_edge_for = 0
			end
			table.insert(case.samples, at)
			if #case.samples > per_second + 1 then
				table.remove(case.samples, 1)
			end
			if #case.samples <= per_second or #plane.orders == 0 then
				case.stuck_for = 0
				continue
			end
			local moved = at - case.samples[1]
			local covered = Vector3.new(moved.X, 0, moved.Z).Magnitude
			if covered < 0.25 * (unit_defs.get(plane.def_name).max_speed :: number) then
				case.stuck_for += config.TICK_DELTA
				if case.stuck_for > case.worst then
					case.worst = case.stuck_for
					case.at = at
					case.from = case.samples[1]
					case.speed = plane.velocity.Magnitude
				end
			else
				case.stuck_for = 0
			end
		end
	end)

	local stuck_limit = args.stuck_seconds or 1
	local edge_limit: number? = args.edge_seconds
	local stuck = {}
	local pinned = {}
	local left = {}
	local slowest: Case? = nil
	local edgiest: Case? = nil
	for _, case in cases do
		if slowest == nil or case.worst > slowest.worst then
			slowest = case
		end
		if edgiest == nil or case.longest_on_edge > edgiest.longest_on_edge then
			edgiest = case
		end
		local wings = (unit_defs.get(case.plane.def_name).air :: any).wings :: types.Wings
		if case.longest_on_edge > (edge_limit or math.pi / wings.turn_rate + 0.5) then
			table.insert(pinned, `{case.name}: {round(case.longest_on_edge, 1)}s on the edge`)
		end
		if case.worst > stuck_limit then
			local at = case.at :: Vector3
			local from = case.from :: Vector3
			table.insert(
				stuck,
				`{case.name}: {round(case.worst + 1, 1)}s at ({round(at.X, 1)}, {round(at.Z, 1)}), a second after`
					.. ` ({round(from.X, 1)}, {round(from.Z, 1)}), flying at {round(case.speed, 1)}`
			)
		end
		if case.left_map then
			table.insert(left, case.name)
		end
	end
	return {
		preset = heightmap.get_preset(),
		half_extents = { round(hx, 1), round(hz, 1) },
		planes = #cases,
		stuck = stuck,
		pinned_to_edge = pinned,
		left_map = left,
		longest_slow = if slowest ~= nil and slowest.worst > 0
			then `{round(slowest.worst, 2)}s, {slowest.name}`
			else "none",
		longest_on_edge = if edgiest ~= nil and edgiest.longest_on_edge > 0
			then `{round(edgiest.longest_on_edge, 2)}s, {edgiest.name}`
			else "none",
		trace = if traced ~= nil then trace else nil,
	}
end

-- A transport, a Hercules or `args.unit`, flying out one way at full speed, is told to come back the other way while
-- it is hit every tick, the way steady fire hits it (`movement.set_impulse`, as `combat` does it). How far it got back
-- toward where it was sent, and how far past where it was turned it drifted on the way out first.
local function hit_control(args: { [string]: any }): Findings
	local transport = unkillable(spawn(args.unit or "hercules", OWN, 0, 0))
	advance(config.TICK_DELTA)
	local out = heightmap.ground_position(0, 400)
	orders.issue(transport, { { kind = "move", position = out, target_id = nil } }, false, false)
	advance(args.run_up or 4)
	local turned_at = transport.position
	local back = heightmap.ground_position(0, -100)
	orders.issue(transport, { { kind = "move", position = back, target_id = nil } }, false, false)
	local furthest_out = 0
	advance(args.seconds or 8, function()
		movement.set_impulse(transport, 0.5)
		furthest_out = math.max(furthest_out, transport.position.Z - turned_at.Z)
	end)
	local findings: Findings = {
		drifted_out = round(furthest_out, 1),
		came_back = round(turned_at.Z - transport.position.Z, 1),
		heading_back = transport.velocity.Z < 0,
	}
	state.mark_dead(transport)
	advance(config.TICK_DELTA)
	return findings
end

-- The nuclear silo is manual fire (`Weapon.manual_fire`): one with a missile ready and an enemy within reach holds
-- its fire until it is ordered to attack, and then launches. A scavengers' silo is given its orders by them
-- (`scavengers`), so it launches with nobody telling it to.
local function nuke_manual(args: { [string]: any }): Findings
	local silo_def = args.silo or "apocalypse"
	local function ready_silo(team: TeamId, x: number): Entity
		local def = unit_defs.get(silo_def)
		local y = unit_defs.surface_height(def, x, 0) + unit_defs.collider_height(def) / 2
		local silo = unkillable(state.create_entity(silo_def, team, Vector3.new(x, y, 0), 0, "active"))
		state.flush()
		silo.weapon_stockpiles[1] = 1
		return silo
	end

	-- the next missile is paid for as it is built, and what it costs is beside the point
	local nocost = require(script.Parent.nocost)
	nocost.set(true)
	local silo = ready_silo(OWN, 0)
	local target = unkillable(spawn("grunt", ENEMY, 120, 0))
	advance(args.seconds or 5)
	local held = silo.weapon_stockpiles[1]
	orders.issue(silo, { { kind = "attack", position = nil, target_id = target.id } }, false, false)
	advance(2)
	local after_order = silo.weapon_stockpiles[1]
	-- the next missile goes on being built through the reload that follows a launch
	local reloading = silo.weapon_reloads[1] > 0
	local progress_before = silo.weapon_stockpile_progress[1]
	advance(5)
	local progress_after = silo.weapon_stockpile_progress[1]
	nocost.set(false)
	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	advance(config.TICK_DELTA)

	local scavenger_silo = ready_silo(config.SCAVENGER_TEAM, 0)
	unkillable(spawn("grunt", OWN, 120, 0))
	advance(args.seconds or 5)
	local scavenger_left = scavenger_silo.weapon_stockpiles[1]
	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	advance(config.TICK_DELTA)

	return {
		held_fire_without_order = held == 1,
		launched_when_ordered = after_order == 0,
		stockpile_grew_while_reloading = reloading and progress_after > progress_before,
		reloading_after_launch = reloading,
		stockpile_progress = { round(progress_before, 2), round(progress_after, 2) },
		scavenger_silo_launched = scavenger_left == 0,
	}
end

-- Drones are a stockpile, as BAR's stockpiling carriers have them (`drones`): a Mantis, or `args.unit`, comes with its
-- first drone, fills its stockpile while that one is out, replaces one that is shot down from the stockpile at once,
-- and, with the stockpile spent, has none out until the next is built.
local function drone_stockpile(args: { [string]: any }): Findings
	local nocost = require(script.Parent.nocost)
	nocost.set(true)
	local carrier = unkillable(spawn(args.unit or "mantis", OWN, 0, 0))
	local spec = unit_defs.get(carrier.def_name).carrier :: types.Carrier
	local function drones_out(): { Entity }
		local out = {}
		for _, entity in state.all() do
			if entity.alive and entity.def_name == spec.drone and entity.team == OWN then
				table.insert(out, entity)
			end
		end
		return out
	end
	advance(config.TICK_DELTA * 2)
	local at_start = { out = #drones_out(), held = carrier.drone_stockpile }

	advance(spec.stockpile.build_time + 0.5)
	local filled = carrier.drone_stockpile

	state.mark_dead(drones_out()[1])
	advance(config.TICK_DELTA * 2)
	local replaced = { out = #drones_out(), held = carrier.drone_stockpile }

	state.mark_dead(drones_out()[1])
	advance(config.TICK_DELTA * 2)
	local spent_out = #drones_out()
	local waited = 0
	while #drones_out() == 0 and waited < spec.stockpile.build_time * 2 do
		advance(config.TICK_DELTA)
		waited += config.TICK_DELTA
	end

	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	advance(config.TICK_DELTA)
	nocost.set(false)
	return {
		starts_with = at_start,
		stockpile_after_build_time = filled,
		after_first_loss = replaced,
		out_after_second_loss = spent_out,
		seconds_until_next = round(waited, 2),
		build_time = spec.stockpile.build_time,
	}
end

-- Takes everything off the map and lets the reaper clear it away.
local function clear_world()
	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	advance(config.TICK_DELTA)
end

-- A reclaimable of `def_name` lying on the ground at (x, z), as `scenery` lays them.
local function lay(def_name: string, x: number, z: number): Entity
	local def = unit_defs.get(def_name)
	local at = unit_defs.surface_position(def, x, z) + Vector3.new(0, unit_defs.collider_height(def) / 2, 0)
	return state.create_reclaimable(def_name, at, 0)
end

-- Reclaimables (`scenery`, `reclaim`). How many of each the map was strewn with, and whether each has its twin across
-- the middle, which needs the test started with `scenery = true`. Then a Construction Bot, or `args.unit`, reclaims a
-- tree and a large rock laid beside it: what each paid out over the base income, and how long it took against BAR's
-- reclaimTime / workertime. Then whether a rock can be raised, shot, blown up or disintegrated, whether it blocks a
-- building, and whether an area reclaim takes the rocks in it.
local function reclaimables(args: { [string]: any }): Findings
	local counts: { [string]: number } = {}
	local unpaired = 0
	local positions: { Vector3 } = {}
	-- what the map was strewn with has not been through a step yet
	state.flush()
	for _, entity in state.all() do
		if entity.kind == "reclaimable" then
			counts[entity.def_name] = (counts[entity.def_name] or 0) + 1
			table.insert(positions, entity.position)
		end
	end
	for _, at in positions do
		local twinned = false
		for _, other in positions do
			if math.abs(other.X + at.X) < 0.01 and math.abs(other.Z + at.Z) < 0.01 then
				twinned = true
				break
			end
		end
		if twinned == false then
			unpaired += 1
		end
	end
	clear_world()

	if state.get_team(OWN) == nil then
		state.create_team(OWN)
	end
	local team = state.get_team(OWN) :: types.Team
	local builder = spawn(args.unit or "construction_bot", OWN, 0, 0)
	local buildpower = unit_defs.get(builder.def_name).buildpower :: number

	-- what one reclaim order brings in over what the team would have made anyway
	local function reclaim_one(target: Entity): Findings
		advance(config.TICK_DELTA)
		team.metal = 0
		team.energy = 0
		local started = sim_time
		orders.issue(builder, { { kind = "reclaim", position = nil, target_id = target.id } }, false, false)
		until_idle(builder, 60)
		local seconds = sim_time - started
		local def = unit_defs.get(target.def_name)
		return {
			gone = target.alive == false,
			metal = round(team.metal - team.metal_income * seconds, 1),
			energy = round(team.energy - team.energy_income * seconds, 1),
			seconds = round(seconds, 2),
			bar_seconds = round(def.buildpower_cost * config.RECLAIMABLE_BUILDPOWER_FRACTION / buildpower, 2),
			holds = { metal = def.metal_cost, energy = def.energy_cost },
		}
	end
	local tree = reclaim_one(lay("tree", 5, 0))
	local rock = reclaim_one(lay("large_rock", -6, 0))

	-- nothing but reclaiming it takes it away
	local resurrection = require(script.Parent.resurrection)
	local placement = require(script.Parent.placement)
	local target = lay("rock", 20, 0)
	local rezzer = spawn("graverobber", OWN, 16, 4)
	-- off to the side, so that its disintegrator, fired at the rock, passes nothing else
	local commander = spawn("commander", OWN, 20, -16)
	advance(config.TICK_DELTA)
	local raisable = resurrection.can_resurrect(rezzer, target)
	local attackable = combat.is_valid_forced_target(commander, target)
	combat.apply_damage(target, 1e6)
	local survived_damage = target.alive
	commander.manual_reload_remaining = 0
	team.energy = team.energy_capacity
	local dgun = combat.manual_fire(commander, target.position)
	advance(config.TICK_DELTA)
	local survived_dgun = target.alive
	local site = placement.resolve_center("solar_collector", target.position.X, target.position.Z, 0, nil)
		or target.position
	local blocks_others = placement.can_place("solar_collector", site, 0, nil, nil) == false
	local cleared_by_builder = placement.can_place("solar_collector", site, 0, nil, OWN)

	-- an area reclaim takes every rock in its circle
	local field = { lay("small_rock", 30, 10), lay("small_rock", 34, 12), lay("rock", 32, 16) }
	orders.issue(
		builder,
		{ { kind = "area_reclaim", position = heightmap.ground_position(32, 12), target_id = nil, radius = 10 } },
		false,
		false
	)
	until_idle(builder, 60)
	local left = 0
	for _, entity in field do
		if entity.alive then
			left += 1
		end
	end
	clear_world()

	return {
		scattered = counts,
		unpaired = unpaired,
		tree = tree,
		large_rock = rock,
		raisable = raisable,
		attackable = attackable,
		survived_damage = survived_damage,
		dgun = dgun,
		survived_dgun = survived_dgun,
		blocks_others = blocks_others,
		cleared_by_builder = cleared_by_builder,
		area_reclaim_left = left,
	}
end

-- What reclaiming shows as the reclaimer's own income (`reclaim`, `flows`): a Construction Bot reclaims a rock, a
-- grunt's wreck and a grunt of its own, and for each, the highest and the average metal and energy rate its infobox
-- read while it worked against what the team actually banked. Then a wreck reclaimed into a full metal store, which
-- banks nothing and should read as stalled on storage.
local function reclaim_income(_args: { [string]: any }): Findings
	local flows = require(script.Parent.flows)
	if state.get_team(OWN) == nil then
		state.create_team(OWN)
	end
	local team = state.get_team(OWN) :: types.Team
	local builder = unkillable(spawn("construction_bot", OWN, 0, 0))

	local function reclaim_watching(target: Entity, full: boolean): Findings
		advance(config.TICK_DELTA)
		team.metal = if full then team.metal_capacity else 0
		team.energy = 0
		local started = sim_time
		local peak_metal, peak_energy, total_metal, total_energy, ticks, stalled = 0, 0, 0, 0, 0, 0
		orders.issue(builder, { { kind = "reclaim", position = nil, target_id = target.id } }, false, false)
		until_idle(builder, 60, function()
			local flow = flows.get(builder.id)
			if flow == nil then
				return
			end
			ticks += 1
			peak_metal = math.max(peak_metal, flow.metal)
			peak_energy = math.max(peak_energy, flow.energy)
			total_metal += flow.metal * config.TICK_DELTA
			total_energy += flow.energy * config.TICK_DELTA
			if flow.stall == "storage" then
				stalled += 1
			end
		end)
		local seconds = sim_time - started
		return {
			gone = target.alive == false,
			seconds = round(seconds, 2),
			peak_rate = { metal = round(peak_metal, 1), energy = round(peak_energy, 1) },
			shown_total = { metal = round(total_metal, 1), energy = round(total_energy, 1) },
			banked = if full
				then nil
				else {
					metal = round(team.metal - team.metal_income * seconds, 1),
					energy = round(team.energy - team.energy_income * seconds, 1),
				},
			ticks_with_flow = ticks,
			ticks_stalled_on_storage = stalled,
		}
	end

	local function wreck_at(x: number, z: number): Entity
		local source = spawn("grunt", ENEMY, x, z)
		local wreck = state.create_wreck(source)
		state.mark_dead(source)
		return wreck
	end

	local findings = {
		rock = reclaim_watching(lay("large_rock", 6, 0), false),
		wreck = reclaim_watching(wreck_at(-6, 0), false),
		standing = reclaim_watching(spawn("grunt", OWN, 0, 6), false),
		wreck_into_full_store = reclaim_watching(wreck_at(0, -6), true),
	}
	clear_world()
	return findings
end

-- Geothermal vents and what stands on them (`geo_spots`, `placement`, `construction`, `drones`), on a map that has
-- vents: run it with `preset` set to one, like "supreme_isthmus" or "koth". Where the map's vents are, and how far each
-- is from the nearest start. With nocost on: a Construction Bot, or `args.unit`, puts a Geothermal Powerplant on the
-- first vent, and what that adds to the team's energy income; whether one can go anywhere off a vent; an Advanced
-- Construction Bot puts an Advanced Geothermal Powerplant over it, and whether the plain one went. Then a Rampart on
-- the second vent: its drones, and whether it shoots down a nuke launched at something beside it.
local function geothermal(args: { [string]: any }): Findings
	local geo_spots = require(ReplicatedStorage.Shared.geo_spots)
	local placement = require(script.Parent.placement)
	local nocost = require(script.Parent.nocost)
	local vents = geo_spots.all()
	local where: { string } = {}
	for _, vent in vents do
		local nearest_start = math.huge
		for slot = 1, starts.count() do
			nearest_start =
				math.min(nearest_start, (starts.center(slot) - Vector2.new(vent.center.X, vent.center.Z)).Magnitude)
		end
		table.insert(
			where,
			`{math.round(vent.center.X)},{math.round(vent.center.Z)} ({math.round(nearest_start)} from a start)`
		)
	end
	local findings: Findings = { vents = #vents, where = where }
	if #vents < 2 then
		return findings
	end
	clear_world()
	if state.get_team(OWN) == nil then
		state.create_team(OWN)
	end
	local team = state.get_team(OWN) :: types.Team
	nocost.set(true)

	-- builds `def_name` on the vent nearest (x, z) with a fresh `unit`, and returns what went up, if anything
	local function build_on(unit: string, def_name: string, x: number, z: number): (Entity?, Vector3?)
		local builder = spawn(unit, OWN, x + 14, z + 14)
		advance(config.TICK_DELTA)
		local site = placement.resolve_center(def_name, x, z, 0, builder.id)
		if site == nil then
			return nil, nil
		end
		orders.issue(
			builder,
			{ { kind = "build", position = site, target_id = nil, def_name = def_name, facing = 0 } },
			false,
			false
		)
		until_idle(builder, 60)
		state.mark_dead(builder)
		for _, entity in state.all() do
			if entity.alive and entity.def_name == def_name and entity.state == "active" then
				return entity, site
			end
		end
		return nil, site
	end

	local vent = vents[1].center
	advance(config.TICK_DELTA)
	local income_before = team.energy_income
	local plant, site = build_on(args.unit or "construction_bot", "geothermal_powerplant", vent.X, vent.Z)
	advance(config.TICK_DELTA)
	findings.plant_built = plant ~= nil
	findings.plant_on_vent = site ~= nil and geo_spots.on_spot(site)
	findings.plant_income = team.energy_income - income_before

	local off_vent = heightmap.ground_position(vent.X + 60, vent.Z + 60)
	local ok, reason = placement.can_place("geothermal_powerplant", off_vent, 0, nil, nil)
	findings.off_vent = { ok = ok, reason = reason }

	income_before = team.energy_income
	local advanced = build_on("advanced_construction_bot", "advanced_geothermal_powerplant", vent.X, vent.Z)
	advance(config.TICK_DELTA)
	findings.advanced_built = advanced ~= nil
	findings.plain_taken_down = plant ~= nil and plant.alive == false
	findings.advanced_income_change = team.energy_income - income_before
	nocost.set(false)

	-- a Rampart on the second vent, with an interceptor ready, and a nuke launched at a grunt beside it
	local other = vents[2].center
	local rampart_def = unit_defs.get "rampart"
	local rampart_at = placement.resolve_center("rampart", other.X, other.Z, 0, nil) :: Vector3
	local rampart = unkillable(state.create_entity("rampart", OWN, rampart_at, 0, "active"))
	advance(1)
	local function drones_out(): number
		local count = 0
		for _, entity in state.all() do
			if entity.alive and entity.def_name == "heavy_drone" and entity.team == OWN then
				count += 1
			end
		end
		return count
	end
	findings.drones_at_start = drones_out()
	nocost.set(true)
	advance((rampart_def.carrier :: types.Carrier).stockpile.build_time + 1)
	nocost.set(false)
	findings.drones_after_build_time = drones_out()

	rampart.weapon_stockpiles[1] = 1
	local mark = unkillable(spawn("grunt", OWN, rampart_at.X + 20, rampart_at.Z))
	-- the silo's side needs a team of its own to launch from
	if state.get_team(ENEMY) == nil then
		state.create_team(ENEMY)
	end
	local silo_def = unit_defs.get "apocalypse"
	-- a quarter of a turn at a time round the Rampart, 250 studs out, until it is on dry land: a silo under the water
	-- launches nothing
	local silo_x, silo_z = rampart_at.X, rampart_at.Z
	for step = 0, 15 do
		local angle = math.atan2(-rampart_at.Z, -rampart_at.X) + step * math.pi / 8
		silo_x = rampart_at.X + math.cos(angle) * 250
		silo_z = rampart_at.Z + math.sin(angle) * 250
		if heightmap.in_bounds(silo_x, silo_z) and heightmap.height_at(silo_x, silo_z) > config.WATER_LEVEL + 2 then
			break
		end
	end
	local silo = unkillable(
		state.create_entity(
			"apocalypse",
			ENEMY,
			unit_defs.surface_position(silo_def, silo_x, silo_z)
				+ Vector3.new(0, unit_defs.collider_height(silo_def) / 2, 0),
			0,
			"active"
		)
	)
	advance(config.TICK_DELTA)
	silo.weapon_stockpiles[1] = 1
	-- fired at the ground under the grunt, as a nuke usually is, since the silo's side cannot see that far
	orders.issue(silo, { { kind = "attack_ground", position = mark.position, target_id = nil } }, false, false)
	local launched = false
	local intercepted = false
	local mark_hurt = false
	advance(args.seconds or 40, function()
		if silo.weapon_stockpiles[1] == 0 then
			launched = true
		end
		if rampart.weapon_stockpiles[1] == 0 then
			intercepted = true
		end
		if mark.health < UNKILLABLE then
			mark_hurt = true
		end
	end)
	findings.silo = {
		alive = silo.alive,
		orders = #silo.orders,
		held = silo.weapon_stockpiles[1],
		at = `{math.round(silo.position.X)},{math.round(silo.position.Y)},{math.round(silo.position.Z)}`,
	}
	findings.nuke_launched = launched
	findings.interceptor_fired = intercepted
	findings.nuke_landed = mark_hurt
	clear_world()
	return findings
end

-- The wind and the tide (`environment`): every map's own are ones that can be, a tidal generator makes as much as the
-- tidal strength however it is set, and the wind keeps to a range set while the game runs. Puts the defaults back.
local function conditions(_args: { [string]: any }): Findings
	local environment = require(ReplicatedStorage.Shared.environment)
	local map_presets = require(ReplicatedStorage.Shared.map_presets)
	local flows = require(script.Parent.flows)
	local wind = require(script.Parent.wind)

	local maps: Findings = {}
	for name, preset in map_presets.presets do
		local ok, reason = environment.apply(preset.conditions or {})
		maps[name] = if ok
			then `{environment.min_wind()}-{environment.max_wind()} tide {environment.tidal_strength()}`
			else reason
	end

	environment.apply({})
	environment.set_tidal(40)
	local generator = spawn("tidal_generator", OWN, 0, 0)
	advance(config.TICK_DELTA * 2)
	local flow = flows.get(generator.id)
	local made_at_40 = if flow ~= nil then flow.energy else nil

	environment.set_wind(5, 6)
	wind.refit()
	local slowest, fastest = math.huge, 0
	advance(20, function()
		slowest = math.min(slowest, wind.speed())
		fastest = math.max(fastest, wind.speed())
	end)

	state.mark_dead(generator)
	advance(config.TICK_DELTA)
	environment.apply({})
	wind.refit()
	return {
		maps = maps,
		tidal_generator_at_40 = made_at_40,
		wind_5_to_6 = { round(slowest, 2), round(fastest, 2) },
	}
end

-- A build order given the way a player's is (`player_route`): a Construction Bot, or `args.unit`, at the foot of the
-- plateau told to put a Solar Collector, or `args.building`, up on it, where it has to find its way round. How many
-- waypoints it was given ahead of the build, whether the blueprint went down, and whether the order was dropped.
local function build_route(args: { [string]: any }): Findings
	local nocost = require(script.Parent.nocost)
	local building = args.building or "solar_collector"
	nocost.set(true)
	local builder = spawn(args.unit or "construction_bot", OWN, 190, -120)
	advance(config.TICK_DELTA)
	-- snapped to the grid the way a player's placement is
	local placement = require(script.Parent.placement)
	local site = placement.resolve_center(building, args.x or 130, args.z or -110, 0, builder.id)
		or heightmap.ground_position(args.x or 130, args.z or -110)
	local placement_ok, placement_reason = placement.can_place(building, site, 0, builder.id)
	local order: types.Order = { kind = "build", position = site, target_id = nil, def_name = building, facing = 0 }
	local steps, sent = player_route(builder, order)
	-- `args.straight` gives it the bare build order, with no route ahead of it, for comparison
	if args.straight then
		steps = { steps[#steps] }
	end
	orders.issue(builder, steps, false, false)
	local started = sim_time
	local placed_at: number? = nil
	local dropped = false
	local deadline = sim_time + (args.seconds or 60)
	while sim_time < deadline and placed_at == nil and dropped == false do
		advance(config.TICK_DELTA)
		for _, entity in state.all() do
			if entity.def_name == building and entity.team == OWN then
				placed_at = sim_time
			end
		end
		dropped = placed_at == nil and #builder.orders == 0
	end
	local findings: Findings = {
		waypoints_sent = sent,
		moves_ahead_of_build = #steps - 1,
		placed = placed_at ~= nil,
		seconds = round((placed_at or sim_time) - started, 2),
		dropped = dropped,
		site_placeable = placement_ok,
		site_reason = placement_reason,
		left_to_go = round(Vector3.new(site.X - builder.position.X, 0, site.Z - builder.position.Z).Magnitude, 1),
	}
	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	advance(config.TICK_DELTA)
	nocost.set(false)
	return findings
end

-- A build order given the way a player's is (`player_route`) for a site up a cliff that a Construction Bot, or
-- `args.unit`, has in reach from where it stands, but could only walk up to the long way round. Found on the map: a
-- spot the bot can stand on with a site for a Solar Collector, or `args.building`, within its reach that it cannot go
-- straight to and that a search finds a way to. How many waypoints the way to the site itself has, how many were sent
-- ahead of the build (none: it builds from where it stands), whether the blueprint went down, and how far the bot
-- went from where it started.
local function build_in_reach(args: { [string]: any }): Findings
	local nocost = require(script.Parent.nocost)
	local placement = require(script.Parent.placement)
	local geometry = require(ReplicatedStorage.Shared.geometry)
	local building = args.building or "solar_collector"
	local unit = args.unit or "construction_bot"
	local def = unit_defs.get(unit)
	local reach = unit_defs.order_reach(def, "build")
	local searches = 0
	local site: Vector3? = nil
	local full_route = 0
	local from = find_spot(function(x: number, z: number): boolean
		if searches >= (args.searches or 200) or heightmap.water_depth(x, z) > 0 then
			return false
		end
		local here = heightmap.ground_position(x, z)
		if pathfinder.has_straight_path(def, here, heightmap.ground_position(x + 4, z)) == false then
			return false
		end
		for index = 0, 7 do
			local angle = index * math.pi / 4
			local center = placement.resolve_center(
				building,
				x + math.cos(angle) * reach * 0.8,
				z + math.sin(angle) * reach * 0.8,
				0,
				nil
			)
			if
				center ~= nil
				and geometry.distance_2d(here, center) <= reach
				and pathfinder.has_straight_path(def, here, center) == false
				and placement.can_place(building, center, 0, nil, OWN)
			then
				searches += 1
				local steps, searched = pathfinder.route(def, here, center, 8000)
				local last = steps[#steps].position
				if searched and #steps >= 3 and last ~= nil and geometry.distance_2d(last, center) <= reach then
					site = center
					full_route = #steps - 1
					return true
				end
			end
		end
		return false
	end)
	if from == nil or site == nil then
		return { found = false, searches = searches }
	end

	nocost.set(true)
	local builder = spawn(unit, OWN, from.X, from.Z)
	local start = builder.position
	advance(config.TICK_DELTA)
	local order: types.Order = { kind = "build", position = site, target_id = nil, def_name = building, facing = 0 }
	local steps, sent = player_route(builder, order)
	orders.issue(builder, steps, false, false)
	local started = sim_time
	local placed_at: number? = nil
	local furthest = 0
	local deadline = sim_time + (args.seconds or 30)
	while sim_time < deadline and placed_at == nil do
		advance(config.TICK_DELTA)
		furthest = math.max(furthest, geometry.distance_2d(builder.position, start))
		for _, entity in state.all() do
			if entity.def_name == building and entity.team == OWN then
				placed_at = sim_time
			end
		end
	end
	local findings: Findings = {
		found = true,
		from = { round(start.X, 1), round(start.Z, 1) },
		site = { round(site.X, 1), round(site.Z, 1) },
		distance = round(geometry.distance_2d(start, site), 1),
		reach = round(reach, 1),
		full_route_waypoints = full_route,
		waypoints_sent = sent,
		moves_ahead_of_build = #steps - 1,
		placed = placed_at ~= nil,
		seconds = round((placed_at or sim_time) - started, 2),
		furthest_from_start = round(furthest, 1),
	}
	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	advance(config.TICK_DELTA)
	nocost.set(false)
	return findings
end

-- A Construction Bot, or `args.unit`, told to build a Fusion Reactor, or `args.building`, whose middle is out of its
-- reach but whose edge is in it, and then to assist the blueprint from as far out again on another side. A builder has
-- a blueprint in reach once its reach touches any part of its collider, so it should start both without taking a step.
-- Whether the blueprint went down and was being worked on by each, and how far each bot moved.
local function build_reach_edge(args: { [string]: any }): Findings
	local placement = require(script.Parent.placement)
	local construction = require(script.Parent.construction)
	local geometry = require(ReplicatedStorage.Shared.geometry)
	local building = args.building or "fusion_reactor"
	local unit = args.unit or "construction_bot"
	local reach = unit_defs.order_reach(unit_defs.get(unit), "build")
	local collider = unit_defs.get(building).collider
	local half = if collider.shape == "box" then collider.width / 2 else collider.radius
	-- past the middle's reach by half of the way to the edge
	local offset = reach + half * 0.5
	local site: Vector3? = nil
	local from = find_spot(function(x: number, z: number): boolean
		if heightmap.water_depth(x, z) > 0 or heightmap.water_depth(x + offset, z) > 0 then
			return false
		end
		local center = placement.resolve_center(building, x + offset, z, 0, nil)
		if
			center == nil
			or heightmap.water_depth(center.X - offset, center.Z) > 0
			or heightmap.water_depth(center.X + offset, center.Z) > 0
			or placement.can_place(building, center, 0, nil, OWN) == false
		then
			return false
		end
		site = center
		return true
	end)
	if from == nil or site == nil then
		return { found = false }
	end
	local center = site :: Vector3
	-- paying for it as usual, so that it is still a blueprint for the second bot to help with
	local builder = spawn(unit, OWN, center.X - offset, center.Z)
	advance(config.TICK_DELTA)
	local start = builder.position
	orders.issue(
		builder,
		{ { kind = "build", position = center, target_id = nil, def_name = building, facing = 0 } },
		false,
		false
	)
	local blueprint: Entity? = nil
	for _ = 1, 30 do
		advance(config.TICK_DELTA)
		for _, entity in state.all() do
			if entity.def_name == building and entity.team == OWN then
				blueprint = entity
			end
		end
	end
	local build_moved = geometry.distance_2d(builder.position, start)
	local building_it = blueprint ~= nil and construction.recent_target_of(builder.id) == blueprint.id

	-- a second bot assisting from out past the other side
	local helper = spawn(unit, OWN, center.X + offset, center.Z)
	advance(config.TICK_DELTA)
	local helper_start = helper.position
	local assisted = false
	if blueprint ~= nil then
		orders.issue(helper, { { kind = "assist", position = nil, target_id = blueprint.id } }, false, false)
		for _ = 1, 30 do
			advance(config.TICK_DELTA)
			if construction.recent_target_of(helper.id) == blueprint.id then
				assisted = true
			end
		end
	end
	local findings: Findings = {
		found = true,
		reach = round(reach, 1),
		half_width = round(half, 1),
		distance_to_middle = round(offset, 1),
		placed = blueprint ~= nil,
		building_it = building_it,
		builder_moved = round(build_moved, 2),
		assisted = assisted,
		helper_moved = round(geometry.distance_2d(helper.position, helper_start), 2),
	}
	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	advance(config.TICK_DELTA)
	return findings
end

-- A move given the way a player's is (`pathfinder.route`, as `commands` does it): a Grunt, or `args.unit`, sent from
-- the low ground at the foot of the plateau up onto it, and then across open ground on the plateau. For each: how
-- many waypoints it was given, whether it needed a search, whether it got there, how long it took, and how long it
-- spent trying to go somewhere and getting nowhere.
local function move_route(args: { [string]: any }): Findings
	local def_name = args.unit or "grunt"
	local def = unit_defs.get(def_name)
	local walker = spawn(def_name, OWN, 190, -120)
	advance(config.TICK_DELTA)

	local function go(to_x: number, to_z: number): Findings
		local destination = heightmap.ground_position(to_x, to_z)
		local route, searched = pathfinder.route(def, walker.position, destination, 8000)
		orders.issue(walker, route, false, false)
		local started = sim_time
		local stuck = 0
		local last = walker.position
		local arrived = until_idle(walker, args.seconds or 60, function()
			local moved = (walker.position - last).Magnitude
			last = walker.position
			if movement.has_goal(walker.id) and moved < 0.05 * config.TICK_DELTA then
				stuck += config.TICK_DELTA
			end
		end)
		local offset = destination - walker.position
		return {
			waypoints = #route,
			searched = searched,
			arrived = arrived,
			seconds = round(sim_time - started, 2),
			seconds_stuck = round(stuck, 2),
			left_to_go = round(Vector3.new(offset.X, 0, offset.Z).Magnitude, 1),
		}
	end
	local alone = {
		up_onto_plateau = go(140, -120),
		across_plateau = go(140, -80),
	}
	state.mark_dead(walker)
	advance(config.TICK_DELTA)

	-- a crowd sent up together, each to its own spot, the way a player's move spreads a group
	local crowd: { Entity } = {}
	for index = 1, args.crowd or 12 do
		table.insert(crowd, spawn(def_name, OWN, 186 + (index % 4) * 3, -126 + (index // 4) * 3))
	end
	advance(config.TICK_DELTA)
	local searches = 0
	for index, member in crowd do
		local spot = heightmap.ground_position(136 + (index % 4) * 3, -124 + (index // 4) * 3)
		local route, searched = pathfinder.route(def, member.position, spot, 8000)
		if searched then
			searches += 1
		end
		orders.issue(member, route, false, false)
	end
	local stuck: { [Entity]: number } = {}
	local last: { [Entity]: Vector3 } = {}
	for _, member in crowd do
		stuck[member] = 0
		last[member] = member.position
	end
	local started = sim_time
	local deadline = sim_time + (args.seconds or 60)
	local arrived = 0
	while sim_time < deadline do
		advance(config.TICK_DELTA, function()
			for _, member in crowd do
				local moved = (member.position - last[member]).Magnitude
				last[member] = member.position
				if movement.has_goal(member.id) and moved < 0.05 * config.TICK_DELTA then
					stuck[member] += config.TICK_DELTA
				end
			end
		end)
		arrived = 0
		for _, member in crowd do
			if #member.orders == 0 then
				arrived += 1
			end
		end
		if arrived == #crowd then
			break
		end
	end
	local worst_stuck = 0
	for _, seconds in stuck do
		worst_stuck = math.max(worst_stuck, seconds)
	end
	alone.crowd = {
		size = #crowd,
		searched = searches,
		arrived = arrived,
		seconds = round(sim_time - started, 2),
		worst_seconds_stuck = round(worst_stuck, 2),
	}
	return alone
end

-- Orders that walk to something, given the way a player's are, with their way laid ahead of them as waypoints
-- (`player_route`): a Grunt, or `args.unit`, on the low ground at the
-- foot of the plateau is told to attack a solar collector up on it, and then, from the same spot, to fight its way to
-- a point on the plateau past another collector where the first one stood, which it can see on the way. For each: whether it got up there, how long it spent
-- trying to go somewhere and getting nowhere, how much it hurt what it was after, and, for the fight, whether it
-- finished.
local function walk_orders(args: { [string]: any }): Findings
	local def_name = args.unit or "grunt"
	local function watch(walker: Entity, seconds: number): (number, boolean)
		local stuck = 0
		local last = walker.position
		local done = until_idle(walker, seconds, function()
			local moved = (walker.position - last).Magnitude
			last = walker.position
			if movement.has_goal(walker.id) and moved < 0.05 * config.TICK_DELTA then
				stuck += config.TICK_DELTA
			end
		end)
		return stuck, done
	end

	local target = unkillable(spawn("solar_collector", ENEMY, 140, -120))
	local attacker = spawn(def_name, OWN, 190, -120)
	advance(config.TICK_DELTA)
	local attack_steps = player_route(attacker, { kind = "attack", target_id = target.id })
	orders.issue(attacker, attack_steps, false, false)
	local attack_stuck = watch(attacker, args.seconds or 40)
	local attack = {
		waypoints_ahead = #attack_steps - 1,
		seconds_stuck = round(attack_stuck, 2),
		height_below_target = round(target.position.Y - attacker.position.Y, 1),
		damage_to_target = round(UNKILLABLE - target.health, 0),
	}
	state.mark_dead(attacker)
	state.mark_dead(target)
	advance(config.TICK_DELTA)

	local passed = unkillable(spawn("solar_collector", ENEMY, args.passed_x or 140, args.passed_z or -120))
	local marcher = spawn(def_name, OWN, 190, -120)
	advance(config.TICK_DELTA)
	local destination = heightmap.ground_position(130, -80)
	local fight_steps, fight_sent = player_route(marcher, { kind = "fight", position = destination })
	orders.issue(marcher, fight_steps, false, false)
	local closest = math.huge
	local stops = 0
	local shot_seconds = 0
	local closest_verdict = ""
	local closest_rise = 0
	local fight_stuck, finished
	do
		local stuck = 0
		local last = marcher.position
		finished = until_idle(marcher, args.seconds or 60, function()
			local moved = (marcher.position - last).Magnitude
			last = marcher.position
			if movement.has_goal(marcher.id) and moved < 0.05 * config.TICK_DELTA then
				stuck += config.TICK_DELTA
			end
			if movement.has_goal(marcher.id) == false and #marcher.orders > 0 then
				stops += 1
			end
			local gap = passed.position - marcher.position
			local flat = Vector3.new(gap.X, 0, gap.Z).Magnitude
			if flat < closest then
				closest_verdict = sight.verdict(marcher, passed, sight.muzzle_of(marcher))
				closest_rise = gap.Y
			end
			closest = math.min(closest, flat)
			if combat.can_shoot(marcher, passed) then
				shot_seconds += config.TICK_DELTA
			end
		end)
		fight_stuck = stuck
	end
	local offset = destination - marcher.position
	local fight = {
		waypoints_sent = fight_sent,
		waypoints_taken = #fight_steps - 1,
		finished = finished,
		seconds_stuck = round(fight_stuck, 2),
		left_to_go = round(Vector3.new(offset.X, 0, offset.Z).Magnitude, 1),
		damage_on_the_way = round(UNKILLABLE - passed.health, 0),
		closest_to_it = round(closest, 1),
		range = round(unit_defs.attack_range(unit_defs.get(def_name)) or 0, 1),
		seconds_stopped = round(stops * config.TICK_DELTA, 2),
		seconds_it_had_a_shot = round(shot_seconds, 2),
		verdict_when_closest = closest_verdict,
		its_height_above_when_closest = round(closest_rise, 1),
	}
	return { attack = attack, fight = fight }
end

-- The map as it was made, run on whatever `args.preset` is: its size and heights, how much of it is under water, where
-- the starts are, how many metal spots it has, what the ground is made of (from the terrain as it was written, read at
-- `args.samples` by `args.samples` points, 48 by default), and whether a bot and a tank can each find their way from
-- the first start to the second. The session then stays up for `args.hold` seconds (none by default), to be looked at.
local function map(args: { [string]: any }): Findings
	local lowest, highest = heightmap.height_bounds()

	local start_list = {}
	for slot = 1, config.START_SLOTS do
		local at = starts.center(slot)
		table.insert(start_list, {
			x = round(at.X, 1),
			z = round(at.Y, 1),
			height = round(heightmap.height_at(at.X, at.Y), 1),
		})
	end

	local rich = 0
	for _, spot in metal_spots.all() do
		if spot.multiplier > 2 then
			rich += 1
		end
	end

	-- the material of the voxel just under the surface, over an even spread of the map
	local samples = args.samples or 48
	local materials: { [string]: number } = {}
	local half_x, half_z = heightmap.half_extents()
	for ix = 1, samples do
		for iz = 1, samples do
			local x = -half_x + (ix - 0.5) / samples * half_x * 2
			local z = -half_z + (iz - 0.5) / samples * half_z * 2
			local y = heightmap.height_at(x, z) - config.CELL_STUDS
			local region = Region3.new(Vector3.new(x - 1, y - 1, z - 1), Vector3.new(x + 1, y + 1, z + 1))
				:ExpandToGrid(config.CELL_STUDS)
			local voxels = Workspace.Terrain:ReadVoxels(region, config.CELL_STUDS)
			local name = voxels[1][1][1].Name
			materials[name] = (materials[name] or 0) + 1
		end
	end

	local from = starts.center(1)
	local to = starts.center(2)
	local function crossing(def_name: string): Findings
		local def = unit_defs.get(def_name)
		local path = pathfinder.find_path(
			def,
			heightmap.ground_position(from.X, from.Y),
			heightmap.ground_position(to.X, to.Y),
			200000
		)
		return { complete = path.complete, waypoints = #path.orders }
	end

	local findings = {
		preset = heightmap.get_preset(),
		lowest = round(lowest, 1),
		highest = round(highest, 1),
		percent_under_water = 0,
		starts = start_list,
		metal_spots = #metal_spots.all(),
		rich_metal_spots = rich,
		materials = materials,
		bot_crossing = crossing "grunt",
		tank_crossing = crossing "incisor",
	}
	local wet = 0
	local total = 0
	local cells_x, cells_z = heightmap.cells()
	for cz = 0, cells_z, 4 do
		for cx = 0, cells_x, 4 do
			local x, z = heightmap.grid_to_world(cx, cz)
			total += 1
			if heightmap.water_depth(x, z) > 0 then
				wet += 1
			end
		end
	end
	findings.percent_under_water = round(wet / total * 100, 1)

	if typeof(args.hold) == "number" then
		task.wait(args.hold)
	end
	return findings
end

-- Replacing the map while the game runs: units on it and a crater in it, then `maps.load` to `args.to` (altair_crossing by
-- default). Afterwards: whether the load went through, what is left of the old world, the map and generation built and
-- published, whether any edit to the old ground came across, and whether the voxels were drawn from the new heightmap.
local function load_map(args: { [string]: any }): Findings
	for index = 1, 5 do
		spawn("grunt", OWN, index * 8, 0)
	end
	advance(config.TICK_DELTA)
	deformation.crater(heightmap.ground_position(0, 40), 12, 5000)
	advance(config.TICK_DELTA)
	local before = map_state.get() :: map_state.MapState
	local edited_before = #heightmap.edited_heights() // 2

	local to = args.to or "altair_crossing"
	local ok, err = maps.load(to, nil)

	local left = 0
	for _ in state.all() do
		left += 1
	end
	local built = map_state.get() :: map_state.MapState
	local published = map_state.published()

	-- the voxels under a few points, against the heightmap they should have been drawn from
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { Workspace.Terrain }
	params.IgnoreWater = true
	local worst = 0
	for _, at in { Vector2.new(-200, -200), Vector2.new(0, 0), Vector2.new(150, -60), Vector2.new(-90, 210) } do
		local expected = heightmap.height_at(at.X, at.Y)
		local hit = Workspace:Raycast(Vector3.new(at.X, 200, at.Y), Vector3.new(0, -400, 0), params)
		worst = math.max(worst, if hit ~= nil then math.abs(hit.Position.Y - expected) else math.huge)
	end

	return {
		loaded = ok,
		error = err,
		generation_before = before.generation,
		generation_after = built.generation,
		preset_after = heightmap.get_preset(),
		published_matches = published ~= nil
			and published.generation == built.generation
			and published.preset == built.preset
			and published.seed == built.seed,
		entities_left = left,
		edited_samples_before = edited_before,
		edited_samples_after = #heightmap.edited_heights() // 2,
		metal_spots = #metal_spots.all(),
		worst_surface_error = round(worst, 2),
	}
end

-- Every map, loaded one after another with `maps.load`: for each, whether it loaded or the error it gave, how long it
-- took, how big it is, and how many metal spots and starts it has.
local function load_every_map(_args: { [string]: any }): Findings
	local names = {}
	for name in map_presets.presets do
		table.insert(names, name)
	end
	table.sort(names)
	local results = {}
	for _, name in names do
		local began = os.clock()
		local ok, err = maps.load(name, nil)
		local half_x, half_z = heightmap.half_extents()
		-- each start box: whether where a player who has not chosen starts is in it and can be started on, and how much
		-- of it can be started on at all, sampled on a grid
		local boxes = {}
		for index = 1, starts.box_count() do
			local box = starts.box(index)
			local spot = starts.default_spot(index)
			local startable, samples = 0, 0
			for row = 0, 15 do
				for column = 0, 15 do
					local x = box.min.X + (box.max.X - box.min.X) * (column + 0.5) / 16
					local z = box.min.Y + (box.max.Y - box.min.Y) * (row + 0.5) / 16
					samples += 1
					if starts.can_start_at(x, z) then
						startable += 1
					end
				end
			end
			boxes[index] = {
				size = `{math.round(box.max.X - box.min.X)}x{math.round(box.max.Y - box.min.Y)}`,
				default_ok = starts.in_box(index, spot.X, spot.Y) and starts.can_start_at(spot.X, spot.Y),
				startable = round(startable / samples, 2),
			}
		end
		results[name] = {
			loaded = ok,
			error = err,
			seconds = round(os.clock() - began, 2),
			size = `{half_x * 2}x{half_z * 2}`,
			metal_spots = #metal_spots.all(),
			start_boxes = boxes,
		}
	end
	return { maps = results }
end

-- Where hovercraft can go on each map, `args.maps` or every one: loaded in turn, and flood filled over the cells a
-- hovercraft's slope class can stand on from every start. For each start, how much of the map it can reach, and whether
-- that takes in the sea; whether every start can reach every other; how much of the shore, dry ground beside the
-- water, a hovercraft can climb.
local function hover_reach(args: { [string]: any }): Findings
	local names: { string } = args.maps
	if names == nil then
		names = {}
		for name in map_presets.presets do
			table.insert(names, name)
		end
		table.sort(names)
	end
	local function is_water(cx: number, cz: number): boolean
		return heightmap.sample(cx, cz) < config.WATER_LEVEL
			and heightmap.sample(cx + 1, cz) < config.WATER_LEVEL
			and heightmap.sample(cx, cz + 1) < config.WATER_LEVEL
			and heightmap.sample(cx + 1, cz + 1) < config.WATER_LEVEL
	end
	local results = {}
	for _, name in names do
		local ok, err = maps.load(name, nil)
		if ok == false then
			results[name] = { error = err }
			continue
		end
		local width, depth = heightmap.cells()
		local water_cells, open_cells = 0, 0
		local shore, climbable_shore = 0, 0
		for cz = 0, depth - 1 do
			for cx = 0, width - 1 do
				local water = is_water(cx, cz)
				if water then
					water_cells += 1
				end
				if passability.passable_cell("HOVER2", cx, cz) then
					open_cells += 1
				end
				if water == false then
					local by_water = (cx > 0 and is_water(cx - 1, cz))
						or (cx < width - 1 and is_water(cx + 1, cz))
						or (cz > 0 and is_water(cx, cz - 1))
						or (cz < depth - 1 and is_water(cx, cz + 1))
					if by_water then
						shore += 1
						if passability.passable_cell("HOVER2", cx, cz) then
							climbable_shore += 1
						end
					end
				end
			end
			if cz % 64 == 0 then
				task.wait()
			end
		end
		-- the region each start is in, for a slope class: a number for each cell, the same across a region
		local function regions(slope_class: string): buffer
			local region = buffer.create(width * depth * 4)
			local next_region = 0
			local stack: { number } = {}
			for cz = 0, depth - 1 do
				for cx = 0, width - 1 do
					local at = cz * width + cx
					if buffer.readu32(region, at * 4) == 0 and passability.passable_cell(slope_class, cx, cz) then
						next_region += 1
						buffer.writeu32(region, at * 4, next_region)
						table.insert(stack, at)
						while #stack > 0 do
							local here = table.remove(stack) :: number
							local hx, hz = here % width, here // width
							for _, step in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
								local nx, nz = hx + step[1], hz + step[2]
								if nx >= 0 and nx < width and nz >= 0 and nz < depth then
									local there = nz * width + nx
									if
										buffer.readu32(region, there * 4) == 0
										and passability.passable_cell(slope_class, nx, nz)
									then
										buffer.writeu32(region, there * 4, next_region)
										table.insert(stack, there)
									end
								end
							end
						end
					end
				end
				if cz % 32 == 0 then
					task.wait()
				end
			end
			return region
		end
		local function reach(slope_class: string): Findings
			local region = regions(slope_class)
			local sizes: { [number]: number } = {}
			local has_water: { [number]: boolean } = {}
			for cz = 0, depth - 1 do
				for cx = 0, width - 1 do
					local id = buffer.readu32(region, (cz * width + cx) * 4)
					if id ~= 0 then
						sizes[id] = (sizes[id] or 0) + 1
						if is_water(cx, cz) then
							has_water[id] = true
						end
					end
				end
			end
			local per_start = {}
			local first: number? = nil
			local all_together = true
			for index = 1, starts.box_count() do
				local spot = starts.default_spot(index)
				local gx, gz = heightmap.world_to_grid(spot.X, spot.Y)
				local id = buffer.readu32(region, (math.floor(gz) * width + math.floor(gx)) * 4)
				if first == nil then
					first = id
				elseif id ~= first then
					all_together = false
				end
				per_start[index] = {
					reaches = round((sizes[id] or 0) / (width * depth), 3),
					sea = has_water[id] == true,
				}
			end
			return { starts = per_start, starts_connected = all_together }
		end
		results[name] = {
			water = round(water_cells / (width * depth), 3),
			hover_open = round(open_cells / (width * depth), 3),
			shore_climbable = if shore > 0 then round(climbable_shore / shore, 3) else "no shore",
			hover = reach "HOVER2",
		}
	end
	return { maps = results }
end

-- What the game made of a match handed in the way a lobby hands one over (`args.match`, which this needs): the map and
-- seed it built, the team each seat was given and which of them are allied, whether the scavengers are on and how far
-- the game's progress got over `args.seconds` (60 by default), which a difficulty's pace sets, and who the game is still
-- waiting for - everyone, since nobody arrives in a test.
local function match_test(args: { [string]: any }): Findings
	local handed = match.get()
	assert(handed ~= nil, "no match was handed in: pass one as `match`")
	local built = map_state.get() :: map_state.MapState

	local seats = {}
	local teams: { TeamId } = {}
	for _, seat in handed.seats do
		-- nil for a spectator
		local team = match.team_of_user(seat.user_id)
		table.insert(seats, { name = seat.name, side = seat.side, team = team })
		if team ~= nil then
			table.insert(teams, team)
		end
	end
	local allied = {}
	for index, a in teams do
		for _, b in { table.unpack(teams, index + 1) } do
			if alliances.are_allied(a, b) then
				table.insert(allied, `{a}+{b}`)
			end
		end
	end

	match.update()
	local progress_before = scavengers.progress()
	local seconds = args.seconds or 60
	advance(seconds)

	-- for a campaign match, what its mission put down, and whether it is still there once the time has run
	local campaign = require(ReplicatedStorage.Shared.campaign)
	local missions = require(script.Parent.missions)
	local enemy = missions.enemy()
	local enemy_things: { [string]: number } = {}
	local boulders = 0
	for _, entity in state.all() do
		if enemy ~= nil and entity.team == enemy then
			enemy_things[entity.def_name] = (enemy_things[entity.def_name] or 0) + 1
		end
		if entity.def_name == "tutorial_boulder" then
			boulders += 1
		end
	end
	return {
		mission = campaign.current_mission(),
		enemy_team = enemy,
		enemy_things = enemy_things,
		boulders = boulders,
		phase = game_phase.phase(),
		mode = handed.mode,
		preset = built.preset,
		seed = built.seed,
		seats = seats,
		allied = allied,
		scavengers_enabled = scavengers.is_enabled(),
		progress_per_minute = round((scavengers.progress() - progress_before) * 60 / seconds, 5),
		awaiting = game_phase.awaiting(),
		is_awaiting = match.is_awaiting(),
	}
end

-- What each seated team's own extractor, solar collector, wind turbine and commander make under the resource bonus its
-- player was given in the match handed in (`args.match`, which this needs), against what their defs say they make. The
-- extractor and the generators should make 1 + bonus / 100 times that and the commander what its def says whatever the
-- bonus, and a converter should convert at its def's rate either way. Every team's things stand together on one metal
-- spot, so they all see the same spot, wind and tide.
local function resource_bonus(_args: { [string]: any }): Findings
	local flows = require(script.Parent.flows)
	local wind = require(script.Parent.wind)
	local economy = require(script.Parent.economy)
	local handed = match.get()
	assert(handed ~= nil, "no match was handed in: pass one as `match`")
	local spot = metal_spots.all()[1].positions[1]

	local teams: { [string]: Findings } = {}
	local ok = true
	for _, seat in handed.seats do
		local team = match.team_of_user(seat.user_id)
		if team == nil then
			continue
		end
		-- nobody arrives in a test, so nobody's team is made for them
		if state.get_team(team) == nil then
			state.create_team(team)
		end
		local extractor = spawn("metal_extractor", team, spot.X, spot.Z)
		local solar = spawn("solar_collector", team, spot.X + 40, spot.Z)
		local turbine = spawn("wind_turbine", team, spot.X, spot.Z + 40)
		local commander = unkillable(spawn("commander", team, spot.X - 40, spot.Z))
		local converter = spawn("energy_converter", team, spot.X, spot.Z - 40)
		-- enough energy over the converters' threshold, and room for their metal, that they run flat out
		local team_state = state.get_team(team) :: types.Team
		advance(config.TICK_DELTA)
		team_state.energy = team_state.energy_capacity
		team_state.metal = 0
		advance(config.TICK_DELTA)

		local scale = 1 + game_modes.bonus_of(handed, seat.user_id) / 100
		local function made(entity: Entity): (number, number)
			local flow = flows.get(entity.id)
			if flow == nil then
				return 0, 0
			end
			return flow.metal, flow.energy
		end
		local extractor_metal = made(extractor)
		local _, solar_energy = made(solar)
		local _, turbine_energy = made(turbine)
		local commander_metal, commander_energy = made(commander)
		local converter_metal = made(converter)
		local commander_def = unit_defs.get "commander"
		local expected = {
			extractor_metal = unit_defs.get("metal_extractor").metal_income :: number * metal_spots.multiplier_at(
				extractor.position
			) * scale,
			solar_energy = unit_defs.get("solar_collector").energy_income :: number * scale,
			turbine_energy = wind.speed() * unit_defs.get("wind_turbine").wind_multiplier :: number * scale,
			commander_metal = commander_def.metal_income :: number,
			commander_energy = commander_def.energy_income :: number,
			converter_metal = (unit_defs.get("energy_converter").energy_conversion :: types.EnergyConversion).metal_per_second,
		}
		local got = {
			extractor_metal = extractor_metal,
			solar_energy = solar_energy,
			turbine_energy = turbine_energy,
			commander_metal = commander_metal,
			commander_energy = commander_energy,
			converter_metal = converter_metal,
		}
		local wrong = {}
		for key, want in expected do
			if math.abs(got[key] - want) > 1e-6 then
				table.insert(wrong, `{key}: {round(got[key], 3)}, not {round(want, 3)}`)
			end
		end
		ok = ok and #wrong == 0
		teams[tostring(team)] = {
			side = seat.side,
			bonus = economy.bonus_of(team),
			made = got,
			wrong = wrong,
		}
		for _, entity in { extractor, solar, turbine, commander, converter } do
			state.mark_dead(entity)
		end
		advance(config.TICK_DELTA)
	end
	return { teams = teams, all_right = ok }
end

-- An unkillable `args.veteran` (a Grunt by default) left to fight `args.count` (3) each of `args.victims` (Grunts and
-- Ticks) set round it in a ring: what it has to show for it after `args.seconds` (40), against what BAR's rules say it
-- should if it made every kill and dealt all the damage itself, 0.2 x the victim's power over its own per kill. Then a
-- friend's shot, which earns nothing.
local function experience(args: { [string]: any }): Findings
	-- a start spot is open ground, where nothing stands between it and the ring (resting on it, not sunk into it, so
	-- the ground is not in the way of its shots)
	local home = starts.default_spot(1)
	local veteran = unkillable(spawn_resting(args.veteran or "grunt", OWN, home.X, home.Y))
	local victims: { Entity } = {}
	local names: { string } = args.victims or { "grunt", "tick" }
	local count = args.count or 3
	local own_power = unit_defs.power(unit_defs.get(veteran.def_name))
	local expected = 0
	for kind, name in names do
		for index = 1, count do
			local angle = ((kind - 1) * count + index) / (#names * count) * 2 * math.pi
			table.insert(
				victims,
				spawn_resting(name, ENEMY, home.X + 16 * math.cos(angle), home.Y + 16 * math.sin(angle))
			)
			expected += 0.2 * unit_defs.power(unit_defs.get(name)) / own_power
		end
	end
	advance(config.TICK_DELTA)
	orders.issue(veteran, { { kind = "fight", position = veteran.position } }, false, false)
	advance(args.seconds or 40)
	local dead = 0
	for _, victim in victims do
		if victim.alive == false then
			dead += 1
		end
	end

	local friend = spawn_resting("grunt", OWN, home.X, home.Y + 40)
	local before = veteran.experience
	combat.apply_damage(friend, 10, veteran.id)
	return {
		victims = #victims,
		dead = dead,
		kills = veteran.kills,
		damage_dealt = round(veteran.damage_dealt, 1),
		score_dealt = round(veteran.score_dealt, 1),
		experience = round(veteran.experience, 4),
		expected_if_all_its_own = round(expected, 4),
		friendly_fire_earned = veteran.experience - before,
	}
end

-- The end screen's stats (match_stats.luau): a grunt of OWN's fights a ring of ENEMY's, then the game is ended in
-- OWN's favour and what that published on Workspace is read back, beside what the grunt itself counted, the enemies
-- that died, and the metal income both teams were on. OWN also has a commander, out of the way, for an income.
local function match_stats_test(args: { [string]: any }): Findings
	-- a test session has no players, so nobody made the teams a game has
	for _, team_id in { OWN, ENEMY } do
		if state.get_team(team_id) == nil then
			state.create_team(team_id).name = `Team {team_id}`
		end
	end
	local home = starts.default_spot(1)
	local veteran = unkillable(spawn_resting("grunt", OWN, home.X, home.Y))
	unkillable(spawn_resting("commander", OWN, home.X - 150, home.Y))
	local victims: { Entity } = {}
	local count = args.count or 4
	for index = 1, count do
		local angle = index / count * 2 * math.pi
		table.insert(
			victims,
			spawn_resting("grunt", ENEMY, home.X + 16 * math.cos(angle), home.Y + 16 * math.sin(angle))
		)
	end
	advance(config.TICK_DELTA)
	orders.issue(veteran, { { kind = "fight", position = veteran.position } }, false, false)
	local seconds = args.seconds or 30
	advance(seconds)
	local dead = 0
	for _, victim in victims do
		if victim.alive == false then
			dead += 1
		end
	end

	game_phase.set_ended({ OWN }, "test")
	task.wait()
	local published = Workspace:GetAttribute(match_stats.ATTRIBUTE)
	local HttpService = game:GetService "HttpService"
	return {
		published_on_end = typeof(published) == "string",
		rows = if typeof(published) == "string" then HttpService:JSONDecode(published) else nil,
		veteran = {
			damage_dealt = round(veteran.damage_dealt, 1),
			score_dealt = round(veteran.score_dealt, 1),
			kills = veteran.kills,
		},
		enemies_dead = dead,
		income = {
			own = (state.get_team(OWN) :: types.Team).metal_income,
			enemy = (state.get_team(ENEMY) :: types.Team).metal_income,
		},
		seconds = seconds,
	}
end

-- Ally griefing (`alliances.may_harm`), off and then on: how much of a shot from OWN's commander an extractor of its
-- own, of an ally's and of an enemy's takes; how much an ally's takes from a shell of OWN's whose shooter is gone;
-- and which of a grunt of each a disintegrator sweeps through survives it.
local function ally_griefing(_args: { [string]: any }): Findings
	local ALLY: TeamId = 3
	for _, team_id in { OWN, ENEMY, ALLY } do
		if state.get_team(team_id) == nil then
			state.create_team(team_id)
		end
	end
	alliances.ally(OWN, ALLY)
	local home = starts.default_spot(1)

	local function run(enabled: boolean): Findings
		alliances.set_ally_griefing(enabled)
		local commander = unkillable(spawn_resting("commander", OWN, home.X, home.Y))
		local mexes = {
			own = spawn_resting("metal_extractor", OWN, home.X - 20, home.Y + 20),
			ally = spawn_resting("metal_extractor", ALLY, home.X, home.Y + 20),
			enemy = spawn_resting("metal_extractor", ENEMY, home.X + 20, home.Y + 20),
		}
		local taken: { [string]: number } = {}
		for owner, mex in mexes do
			local before = mex.health
			combat.apply_damage(mex, 100, commander.id)
			taken[owner] = before - mex.health
		end
		local before = mexes.ally.health
		combat.apply_damage(mexes.ally, 100, -1, OWN)
		local orphan_shell = before - mexes.ally.health

		-- a row straight ahead of the commander, along -z, well inside the disintegrator's reach
		local row = {
			own = spawn_resting("grunt", OWN, home.X, home.Y - 8),
			ally = spawn_resting("grunt", ALLY, home.X, home.Y - 13),
			enemy = spawn_resting("grunt", ENEMY, home.X, home.Y - 18),
		}
		advance(config.TICK_DELTA)
		commander.manual_reload_remaining = 0
		local team = state.get_team(OWN) :: types.Team
		team.energy = team.energy_capacity
		local dgun = combat.manual_fire(commander, Vector3.new(home.X, 0, home.Y - 30))
		advance(config.TICK_DELTA)
		local survived: { [string]: boolean } = {}
		for owner, grunt in row do
			survived[owner] = grunt.alive
		end
		clear_world()
		return { taken = taken, orphan_shell = orphan_shell, dgun = dgun, survived_dgun = survived }
	end

	local findings = { off = run(false), on = run(true) }
	alliances.set_ally_griefing(false)
	return findings
end

-- Giving resources from the player list (sharing.luau): only to an ally, never more than the giver has or the taker
-- has room for, and nothing for a request that makes no sense. Works on teams of its own, straight on their banks.
local function resource_sharing(_args: { [string]: any }): Findings
	local giver = state.create_team(9101)
	local ally = state.create_team(9102)
	local enemy = state.create_team(9103)
	alliances.ally(giver.id, ally.id)
	local function reset()
		giver.metal, giver.metal_capacity, giver.energy, giver.energy_capacity = 300, 1000, 500, 1000
		ally.metal, ally.metal_capacity, ally.energy, ally.energy_capacity = 0, 5000, 900, 1000
		enemy.metal, enemy.metal_capacity, enemy.energy, enemy.energy_capacity = 0, 1000, 0, 1000
	end

	reset()
	local capped_by_room = sharing.share(giver.id, ally.id, "energy", 400)
	local room_banks = { giver = giver.energy, ally = ally.energy }
	reset()
	local capped_by_stock = sharing.share(giver.id, ally.id, "metal", 1000)
	local stock_banks = { giver = giver.metal, ally = ally.metal }
	reset()
	local to_enemy = sharing.share(giver.id, enemy.id, "metal", 100)
	local to_self = sharing.share(giver.id, giver.id, "metal", 100)
	local no_team = sharing.share(nil, ally.id, "metal", 100)
	local bad_resource = sharing.share(giver.id, ally.id, "gold", 100)
	local nan = sharing.share(giver.id, ally.id, "metal", 0 / 0)
	local negative = sharing.share(giver.id, ally.id, "metal", -50)
	local huge = sharing.share(giver.id, ally.id, "metal", math.huge)
	local rejected_left_banks = giver.metal == 300 and ally.metal == 0 and enemy.metal == 0

	return {
		-- 400 asked, the ally has room for 100
		capped_by_room = capped_by_room,
		room_banks = room_banks,
		-- 1000 asked, the giver has 300
		capped_by_stock = capped_by_stock,
		stock_banks = stock_banks,
		rejected = {
			to_enemy = to_enemy,
			to_self = to_self,
			no_team = no_team,
			bad_resource = bad_resource,
			nan = nan,
			negative = negative,
			huge = huge,
		},
		rejected_left_banks = rejected_left_banks,
		pass = capped_by_room == 100
			and room_banks.giver == 400
			and room_banks.ally == 1000
			and capped_by_stock == 300
			and stock_banks.giver == 0
			and stock_banks.ally == 300
			and to_enemy + to_self + no_team + bad_resource + nan + negative + huge == 0
			and rejected_left_banks,
	}
end

-- Skins (shared/skins). Special skins are opt in: a unit of a team nobody chose a skin for wears the plain default. A
-- team put in the pool skin has its unit re-skinned, and the def is as it is, the very same table; the golden skin, put
-- on a team that already has a unit, doubles that unit's health (keeping it full) and stretches and strengthens its
-- weapon, and what the team makes after wears it too. Then two duels between `args.def` (grunt by default): a golden
-- one against a plain one at 80% of the plain range, for `args.seconds` (30 by default), and a golden one against a
-- plain one standing at 130% of the plain range, out of its reach, for 10 seconds, which only the golden one should be
-- hurting.
local function skins_test(args: { [string]: any }): Findings
	local def_name = args.def or "grunt"
	for _, team_id in { OWN, ENEMY } do
		if state.get_team(team_id) == nil then
			state.create_team(team_id)
		end
	end
	local base = unit_defs.get(def_name)
	local base_weapon = (base.weapons :: { types.Weapon })[1]

	local first = spawn(def_name, OWN, -40, -40)
	state.flush()
	local unchosen = { skin = first.skin, same_def = unit_defs.of(first) == base, max_health = first.max_health }
	server_skins.set_team(OWN, "pool")
	local pool = { skin = first.skin, same_def = unit_defs.of(first) == base, max_health = first.max_health }

	server_skins.set_team(OWN, "golden")
	local golden = unit_defs.of(first)
	local golden_weapon = (golden.weapons :: { types.Weapon })[1]
	local reskinned = {
		skin = first.skin,
		health = round(first.health, 1),
		max_health = round(first.max_health, 1),
		range = round(golden_weapon.range / base_weapon.range, 3),
		damage = round(golden_weapon.damage / base_weapon.damage, 3),
		same_table_again = unit_defs.of(first) == golden,
	}
	local later = spawn(def_name, OWN, -40, -30)
	state.flush()

	-- a golden one against a plain one, `distance` apart on open ground, the golden one ordered to attack, and the
	-- plain one too if `both`
	local home = starts.default_spot(1)
	local function duel(distance: number, seconds: number, both: boolean): { [string]: any }
		local ours = spawn_resting(def_name, OWN, home.X, home.Y)
		local theirs = spawn_resting(def_name, ENEMY, home.X + distance, home.Y)
		advance(config.TICK_DELTA)
		orders.issue(ours, { { kind = "attack", target_id = theirs.id } }, false, false)
		if both then
			orders.issue(theirs, { { kind = "attack", target_id = ours.id } }, false, false)
		end
		local our_start, their_start = ours.health, theirs.health
		advance(seconds)
		return {
			golden_alive = ours.alive,
			plain_alive = theirs.alive,
			golden_lost = round(our_start - math.max(0, ours.health), 1),
			plain_lost = round(their_start - math.max(0, theirs.health), 1),
		}
	end
	clear_world()
	local close = duel(base_weapon.range * 0.8, args.seconds or 30, true)
	clear_world()
	local far = duel(base_weapon.range * 1.3, 10, false)

	server_skins.set_team(OWN, config.DEFAULT_SKIN)
	return {
		default_skin = config.DEFAULT_SKIN,
		unchosen = unchosen,
		pool = pool,
		golden_reskinned = reskinned,
		golden_made_later = { skin = later.skin, max_health = later.max_health },
		players_may_wear_golden = shared_skins.may_wear("golden", false),
		developers_may_wear_golden = shared_skins.may_wear("golden", true),
		close_duel = close,
		out_of_reach = far,
	}
end

-- The tutorial's boulder (missions.luau, obstacles.luau, combat's DGUN_ONLY), on the tutorial map built afresh with the
-- boulder in its pass and nothing else. First, what does nothing to it: a grunt's shots at it for `args.seconds` (6),
-- a commander's death blast beside it, a huge blow dealt it straight, and whether it can be reclaimed. Then a grunt told
-- to walk through the pass to the far side, which should get no further than the boulder's face in 12 seconds. Then a
-- commander disintegrating it, which should take one shot. Then the grunt told again, which should now get
-- through. `pass` is all of it.
local function tutorial_boulder(args: { [string]: any }): Findings
	local campaign = require(ReplicatedStorage.Shared.campaign)
	local missions = require(script.Parent.missions)
	local reclaim = require(script.Parent.reclaim)
	local loaded, err = maps.load("tutorial", game_modes.DEFAULT_SEED)
	assert(loaded, err)
	scenery.clear()
	if state.get_team(OWN) == nil then
		state.create_team(OWN)
	end
	local team = state.get_team(OWN) :: types.Team
	local layout = campaign.TUTORIAL
	local boulder = missions.place_boulder(layout.chokepoint)
	local full = boulder.health
	-- the boulder's face toward the player: it is turned so that its shorter side runs along the pass
	local half = unit_defs.footprint_half_extents(unit_defs.get(boulder.def_name))
	local face_x = layout.chokepoint.X - math.min(half.X, half.Y)
	local west = layout.chokepoint.X - 44
	local east = layout.chokepoint.X + 44
	local under = heightmap.ground_position(layout.chokepoint.X, layout.chokepoint.Y)

	-- what should do nothing: a commander going up beside it, off to one side so that it takes nothing else with it,
	-- a blow far past its health, a builder, and a grunt shooting at it
	local blast = spawn("commander", 3, layout.chokepoint.X - 10, layout.chokepoint.Y + 30)
	advance(config.TICK_DELTA)
	combat.apply_damage(blast, 1e9, nil)
	advance(config.TICK_DELTA)
	local after_blast = boulder.health
	combat.apply_damage(boulder, 1e9, nil)
	local after_blow = boulder.health
	local builder = spawn("construction_bot", OWN, west, layout.chokepoint.Y - 12)
	advance(config.TICK_DELTA)
	local reclaimable = reclaim.can_reclaim(builder, boulder)
	state.mark_dead(builder)
	local grunt = spawn("grunt", OWN, west, layout.chokepoint.Y)
	advance(config.TICK_DELTA)
	orders.issue(grunt, { { kind = "attack_ground", position = boulder.position, target_id = nil } }, false, false)
	advance(args.seconds or 6)
	local grunt_shots = combat.shots_of(grunt.id, 1)
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

	-- disintegrating it
	team.energy_capacity = 100000
	team.energy = 100000
	local commander = spawn("commander", OWN, west - 6, layout.chokepoint.Y)
	advance(config.TICK_DELTA)
	local healths = {}
	local shots = 0
	while boulder.alive and shots < 6 do
		team.energy = 100000
		orders.issue(commander, { { kind = "dgun", position = under, target_id = nil } }, false, false)
		until_idle(commander, 15)
		shots += 1
		table.insert(healths, math.max(0, boulder.health))
	end
	advance(config.TICK_DELTA)
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
			and blocked_reach < face_x + config.CELL_STUDS
			and destroyed
			and shots == 1
			and wrecks == 0
			and open_reach > east - 8,
	}
end

-- The tutorial's end (missions.luau): the mission set up as a lobby's match would have it (hand one in with
-- `match = { mode = "campaign_tutorial", ... }`), or else here, on the tutorial map. After a second the game should not
-- have ended (`phase_before`); the enemy should have 3 extractors, each on a metal spot. Then everything of the enemy's is killed
-- outright, leaving wrecks, and a second later the game should have ended, won by everyone but the enemy, with the enemy
-- destroyed. Nobody plays in a test, so `completed_for` (the players the mission was marked complete for) is empty
-- unless someone is here.
local function tutorial_victory(_args: { [string]: any }): Findings
	local campaign = require(ReplicatedStorage.Shared.campaign)
	local missions = require(script.Parent.missions)
	-- lets the server finish starting, so that it sets the phase to playing before this can end the game, not after
	task.wait()
	if missions.enemy() == nil then
		local loaded, err = maps.load("tutorial", game_modes.DEFAULT_SEED)
		assert(loaded, err)
		scenery.clear()
		Workspace:SetAttribute(campaign.MISSION_ATTRIBUTE, "tutorial")
		missions.setup()
	end
	local enemy = missions.enemy() :: TeamId
	advance(1)
	local phase_before = game_phase.phase()
	local extractors, on_spots, killed = 0, 0, 0
	for _, entity in state.all() do
		if entity.team ~= enemy or (entity.kind ~= "unit" and entity.kind ~= "building") then
			continue
		end
		if entity.def_name == "metal_extractor" then
			extractors += 1
			if metal_spots.multiplier_at(entity.position) ~= 1 then
				on_spots += 1
			end
		end
		combat.apply_damage(entity, 1e9, nil)
		killed += 1
	end
	advance(1)
	local completed_for = {}
	for _, player in Players:GetPlayers() do
		if missions.was_completed_for(player.UserId) then
			table.insert(completed_for, player.Name)
		end
	end
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
		completed_for = completed_for,
		pass = phase_before ~= "ended"
			and extractors == 3
			and on_spots == 3
			and game_phase.phase() == "ended"
			and missions.result() == "won"
			and table.find(winners, enemy) == nil,
	}
end

-- The overlook (missions.luau, on the "overlook" map), set up as a lobby's match would have it (hand one in with
-- `match = { mode = "campaign_overlook", ... }`), or else here. First the ground: the plateau under the player's start
-- and the low ground under the enemy's (`drop` should be about 28), how far the cliff's edge wanders (`edge_xs`), and a
-- grunt's route from one start to the other, which should be found and go round by a ramp (`route_widest_z` near 72)
-- rather than down the cliff. Then the enemy: 20 things in all, 2 extractors on their spots, and full storage a second
-- in. Then what can be reached from the cliff: for each of the enemy's things, a thug put at the edge in line with it,
-- and whether it could shoot it from there (`in_reach`, about half) and whether the thing could shoot back (`fire_back`,
-- none). Then what the mission is about, each told to attack as a player would: a thug at the edge against the front
-- guard nearest z = 0, which it should kill without being hit, and an aggravator on the low ground against the guard at
-- the foot of the south ramp, from `args.gap` (42) studs, which it should hold at and kill without being hit, since its
-- rockets outreach a guard on the level. Each gets `args.seconds` (45).
local function overlook(args: { [string]: any }): Findings
	local campaign = require(ReplicatedStorage.Shared.campaign)
	local geometry = require(ReplicatedStorage.Shared.geometry)
	local missions = require(script.Parent.missions)
	-- lets the server finish starting, so that it sets the phase to playing before this can end the game, not after
	task.wait()
	if missions.enemy() == nil then
		local loaded, err = maps.load("overlook", game_modes.DEFAULT_SEED)
		assert(loaded, err)
		scenery.clear()
		Workspace:SetAttribute(campaign.MISSION_ATTRIBUTE, "overlook")
		missions.setup()
	end
	if state.get_team(OWN) == nil then
		state.create_team(OWN)
	end
	local enemy = missions.enemy() :: TeamId
	local layout = campaign.OVERLOOK
	local seconds = args.seconds or 45

	-- the ground
	local top = heightmap.height_at(layout.player_start.X, layout.player_start.Y)
	local bottom = heightmap.height_at(layout.enemy_start.X, layout.enemy_start.Y)
	local edge_xs: { number } = {}
	for z = -60, 60, 20 do
		table.insert(edge_xs, round(campaign.overlook_edge_at(z), 1))
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
		if entity.def_name == "metal_extractor" and metal_spots.multiplier_at(entity.position) ~= 1 then
			extractors_on_spots += 1
		end
		table.insert(things, entity)
	end
	local team = state.get_team(enemy) :: types.Team
	local stored = round(team.energy, 0)
	local capacity = team.energy_capacity

	-- what a thug at the edge reaches
	local in_reach: { string } = {}
	local fire_back: { string } = {}
	for _, thing in things do
		local z = thing.position.Z
		local thug = spawn("thug", OWN, campaign.overlook_edge_at(z) - 1, z)
		advance(config.TICK_DELTA)
		local label = `{thing.def_name}@{math.round(thing.position.X)},{math.round(z)}`
		if combat.can_shoot(thug, thing) then
			table.insert(in_reach, label)
		end
		if combat.can_shoot(thing, thug) then
			table.insert(fire_back, label)
		end
		state.mark_dead(thug)
		advance(config.TICK_DELTA)
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
		advance(config.TICK_DELTA)
		local start = attacker.position
		local full = attacker.health
		orders.issue(attacker, { { kind = "attack", position = nil, target_id = guard.id } }, false, false)
		local killed_at: number? = nil
		local elapsed = 0
		advance(seconds, function()
			elapsed += config.TICK_DELTA
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
	local thug = duel("thug", campaign.overlook_edge_at(front.position.Z) - 1, front.position.Z, front)
	local ramp_guard = nearest("guard", 46, -62)
	local gap = args.gap or 42
	local aggravator = duel("aggravator", ramp_guard.position.X + gap, ramp_guard.position.Z, ramp_guard)

	return {
		plateau = round(top, 1),
		low_ground = round(bottom, 1),
		drop = round(top - bottom, 1),
		edge_xs = edge_xs,
		route_found = found,
		route_waypoints = #route,
		route_widest_z = round(widest_z, 1),
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
			and widest_z > 50
			and total == 20
			and extractors_on_spots == 2
			and stored == capacity
			and #in_reach >= 8
			and #in_reach <= 12
			and #fire_back == 0
			and thug.guard_dead
			and thug.damage_taken == 0
			and aggravator.guard_dead
			and aggravator.damage_taken == 0,
	}
end

-- The load_mission command's work (maps.load_mission): the tutorial loaded, the game then ended as though it had been
-- won, and the overlook loaded over it. The overlook should be what is played (`mission`), with its enemy's 8 guards
-- and nothing left of the tutorial's boulder or its enemy's grunts, its enemy playing as the tutorial's did (no empty
-- team left behind), and the game playing again with no winners. A mission there is not should be refused.
local function load_mission(_args: { [string]: any }): Findings
	local campaign = require(ReplicatedStorage.Shared.campaign)
	local missions = require(script.Parent.missions)
	task.wait()
	local tutorial_ok, tutorial_err = maps.load_mission "tutorial"
	local tutorial_enemy = missions.enemy()
	local boulder_before = Workspace:GetAttribute "campaign_boulder"
	game_phase.set_ended({ OWN }, "test")
	local ended = game_phase.phase()
	local teams_before = 0
	for _ in state.all_teams() do
		teams_before += 1
	end

	local ok, err = maps.load_mission "overlook"
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
	local enemy = missions.enemy()
	local refused, refusal = maps.load_mission "nowhere"
	return {
		tutorial_loaded = tutorial_ok,
		tutorial_error = tutorial_err,
		boulder_before = boulder_before,
		phase_after_win = ended,
		loaded = ok,
		error = err,
		mission = campaign.current_mission(),
		preset = (map_state.get() :: map_state.MapState).preset,
		tutorial_enemy = tutorial_enemy,
		enemy = enemy,
		teams_before = teams_before,
		teams_after = teams_after,
		counts = counts,
		boulder_after = Workspace:GetAttribute "campaign_boulder",
		phase = game_phase.phase(),
		winners = game_phase.winners(),
		refused = refused == false,
		refusal = refusal,
		pass = tutorial_ok
			and boulder_before ~= nil
			and ended == "ended"
			and ok
			and campaign.current_mission() == "overlook"
			and enemy ~= nil
			and enemy == tutorial_enemy
			and teams_after == teams_before
			and counts[`{enemy}:guard`] == 8
			and counts[`{enemy}:grunt`] == 4
			and counts["0:tutorial_boulder"] == nil
			and Workspace:GetAttribute "campaign_boulder" == nil
			and game_phase.phase() == "playing"
			and #game_phase.winners() == 0
			and refused == false,
	}
end

-- Construction Bots, `args.builders` of them (1 by default) or of `args.unit`, given a bare build order (no route) for a
-- Solar Collector, or `args.building`, `args.gap` studs past the far side of an Advanced Fusion Reactor, or
-- `args.obstacle`, so that they walk into the obstacle and are held against it, or build from the edge of their reach
-- over it. With `args.paid` it is paid for and takes its time; otherwise nocost finishes it on the spot. For
-- `args.seconds` (15 by default), over all of them: how often one turned more than a quarter turn in one tick (none
-- should flip round and back while pushed); on how many ticks one was moving back, away from the site, each of which
-- used to turn it right round; how close one got to the obstacle; and whether the blueprint went down. `args.trace`
-- also gives where the first was, which way it faced and its first order, each half second.
local function builder_blocked(args: { [string]: any }): Findings
	local nocost = require(script.Parent.nocost)
	local building = args.building or "solar_collector"
	local obstacle_name = args.obstacle or "advanced_fusion_reactor"
	local def = unit_defs.get(args.unit or "construction_bot")
	local reach = unit_defs.order_reach(def, "build")
	local obstacle_half = unit_defs.get(obstacle_name).collider.length / 2
	local site_half = unit_defs.get(building).collider.length / 2
	nocost.set(args.paid ~= true)
	local obstacle = unkillable(spawn(obstacle_name, OWN, 0, 0))
	local site_z = obstacle_half + site_half + (args.gap or 4)
	local builders: { Entity } = {}
	local count = args.builders or 1
	for index = 1, count do
		local x = (index - (count + 1) / 2) * 3
		table.insert(builders, spawn(args.unit or "construction_bot", OWN, x, -(obstacle_half + reach + 10)))
	end
	advance(config.TICK_DELTA)
	local site = heightmap.ground_position(0, site_z)
	for _, builder in builders do
		orders.issue(
			builder,
			{ { kind = "build", position = site, target_id = nil, def_name = building, facing = 0 } },
			false,
			false
		)
	end
	local flips, ticks, pushed_back = 0, 0, 0
	local closest = math.huge
	local placed = false
	local facings: { number } = {}
	for index, builder in builders do
		facings[index] = builder.facing
	end
	local trace: { string } = {}
	advance(args.seconds or 15, function()
		ticks += 1
		local first = builders[1]
		if args.trace and ticks % 10 == 0 then
			local order = first.orders[1]
			table.insert(
				trace,
				`{round(first.position.X, 1)},{round(first.position.Z, 1)} f{math.round(math.deg(first.facing))} {if order
					then order.kind
					else "-"}`
			)
		end
		for index, builder in builders do
			local turn = (builder.facing - facings[index] + math.pi) % (2 * math.pi) - math.pi
			if math.abs(turn) > math.pi / 2 then
				flips += 1
			end
			facings[index] = builder.facing
			if
				builder.velocity.Magnitude > config.MOVEMENT_SETTLE_SPEED
				and builder.velocity:Dot(site - builder.position) < 0
			then
				pushed_back += 1
			end
			closest = math.min(closest, math.abs(builder.position.Z - obstacle.position.Z) - obstacle_half)
		end
		for _, entity in state.all() do
			if entity.def_name == building and entity.team == OWN then
				placed = true
			end
		end
	end)
	local findings: Findings = {
		reach = round(reach, 1),
		obstacle_half = round(obstacle_half, 1),
		site_z = round(site_z, 1),
		flips = flips,
		pushed_back = pushed_back,
		ticks = ticks,
		closest_to_obstacle = round(closest, 2),
		placed = placed,
		trace = if args.trace then table.concat(trace, " | ") else nil,
	}
	for _, entity in state.all() do
		state.mark_dead(entity)
	end
	advance(config.TICK_DELTA)
	nocost.set(false)
	return findings
end

-- The pool skin's donut as the server keeps it (server/donuts.luau), which is what every client draws. A pool grunt:
-- its donut is on once it is finished, a hit pops it (published `donut_event` "1:pop"), it stays off for
-- `regen_seconds` and is on again after. A pool Valiant ordered across the map flat out: how far its shake got and
-- when its donut flew off. A commander (amphibious) set down on the sea floor, `args.depth` deep (8 by default): its
-- donut floats off ("float") and stays off past `regen_seconds` while it is still down there; and a ship on the water
-- beside it keeps its own. A golden grunt wears none. Then the debug calls: force_off and force_on.
local function donut_state(args: { [string]: any }): Findings
	for _, team_id in { OWN, ENEMY } do
		if state.get_team(team_id) == nil then
			state.create_team(team_id)
		end
	end
	server_skins.set_team(OWN, "pool")
	local settings = (shared_skins.get("pool").attachments[1] :: types.SkinAttachment).donut
	local grunt = spawn(args.def or "grunt", OWN, -60, -60)
	advance(config.TICK_DELTA * 2)
	local first = donuts.published(grunt)

	combat.apply_damage(grunt, 10, nil)
	advance(config.TICK_DELTA)
	local popped = donuts.published(grunt)
	advance(settings.regen_seconds - 1)
	local before_regen = donuts.published(grunt)
	advance(2)
	local after_regen = donuts.published(grunt)

	local plane = spawn("valiant", OWN, -150, 0)
	advance(config.TICK_DELTA)
	orders.issue(plane, { { kind = "move", position = heightmap.ground_position(150, 0) } }, false, false)
	local most_shake, flew_at = 0, nil :: number?
	local started = sim_time
	advance(args.seconds or 20, function()
		local published = donuts.published(plane)
		if published == nil then
			return
		end
		most_shake = math.max(most_shake, published.shake)
		if flew_at == nil and published.event ~= nil and string.find(published.event, "fly") ~= nil then
			flew_at = round(sim_time - started, 1)
		end
	end)

	local depth = args.depth or 8
	local sea = find_spot(function(x: number, z: number): boolean
		return deep_all_round(x, z, depth, 12)
	end)
	local underwater: { [string]: any } = { found = sea ~= nil }
	if sea ~= nil then
		local diver = spawn_resting("commander", OWN, sea.X, sea.Z)
		local ship = spawn_resting(args.ship or "supporter", OWN, sea.X + 20, sea.Z)
		advance(config.TICK_DELTA * 2)
		underwater.under_the_surface = round(config.WATER_LEVEL - diver.position.Y, 1)
		underwater.diver = donuts.published(diver)
		underwater.ship = donuts.published(ship)
		advance(settings.regen_seconds + 2)
		underwater.diver_after_regen_time = donuts.published(diver)
		underwater.ship_after = donuts.published(ship)
	end

	server_skins.set_team(OWN, "golden")
	advance(config.TICK_DELTA)
	local golden = donuts.published(grunt)
	server_skins.set_team(OWN, "pool")
	advance(config.TICK_DELTA * 2)
	local forced_off = donuts.force_off(grunt, "pop")
	local after_force_off = donuts.published(grunt)
	local forced_on = donuts.force_on(grunt)
	local after_force_on = donuts.published(grunt)
	server_skins.set_team(OWN, config.DEFAULT_SKIN)
	return {
		first = first,
		popped = popped,
		before_regen = before_regen,
		after_regen = after_regen,
		plane = { max_speed = unit_defs.get("valiant").max_speed, most_shake = most_shake, flew_off_after = flew_at },
		underwater = underwater,
		golden = golden or "none",
		forced_off = forced_off,
		after_force_off = after_force_off,
		forced_on = forced_on,
		after_force_on = after_force_on,
	}
end

-- How evenly `points` sit round `center`: how many of `sectors` equal slices of the circle round it hold at least one,
-- the widest gap between two of them going round, in degrees, and each one's distance to its nearest neighbour, least
-- and on average, and to the middle, least and most.
local function spread_round(center: Vector3, points: { Vector3 }, sectors: number): Findings
	local angles: { number } = {}
	local occupied: { [number]: boolean } = {}
	local nearest_middle, furthest_middle = math.huge, 0
	for _, point in points do
		local away = Vector3.new(point.X - center.X, 0, point.Z - center.Z)
		local angle = math.atan2(away.Z, away.X) % (2 * math.pi)
		table.insert(angles, angle)
		occupied[math.floor(angle / (2 * math.pi) * sectors)] = true
		nearest_middle = math.min(nearest_middle, away.Magnitude)
		furthest_middle = math.max(furthest_middle, away.Magnitude)
	end
	table.sort(angles)
	local widest_gap = 0
	for index, angle in angles do
		local following = if index < #angles then angles[index + 1] else angles[1] + 2 * math.pi
		widest_gap = math.max(widest_gap, following - angle)
	end
	local least_apart, total_apart = math.huge, 0
	for index, point in points do
		local nearest = math.huge
		for other_index, other in points do
			if other_index ~= index then
				nearest = math.min(nearest, Vector3.new(point.X - other.X, 0, point.Z - other.Z).Magnitude)
			end
		end
		least_apart = math.min(least_apart, nearest)
		total_apart += nearest
	end
	local filled = 0
	for _ in occupied do
		filled += 1
	end
	return {
		sectors_filled = `{filled}/{sectors}`,
		widest_gap_degrees = round(math.deg(widest_gap), 0),
		nearest_neighbour_least = round(least_apart, 2),
		nearest_neighbour_mean = round(total_apart / math.max(#points, 1), 2),
		from_middle = { round(nearest_middle, 1), round(furthest_middle, 1) },
	}
end

-- `args.count` (40) flying builders, `args.unit` or Advanced Construction Aircraft, all sent from one clump to assist
-- one blueprint, `args.target` or an Epic Fusion Reactor, for `args.seconds` (90). How they are spread round it once
-- they have arrived (`arrived`, ten seconds in) and at the end (`settled`), how many still assist it, and the range
-- they have to keep within.
local function air_ring(args: { [string]: any }): Findings
	local unit = args.unit or "advanced_construction_aircraft"
	local count = args.count or 40
	local blueprint =
		state.create_entity(args.target or "epic_fusion_reactor", OWN, heightmap.ground_position(0, 0), 0, "blueprint")
	local builders: { Entity } = {}
	for index = 1, count do
		local builder = spawn(unit, OWN, -90 + (index % 7) * 2, -6 + math.floor(index / 7) * 2)
		table.insert(builders, builder)
	end
	advance(config.TICK_DELTA)
	for _, builder in builders do
		orders.issue(builder, { { kind = "assist", target_id = blueprint.id } }, false, false)
	end
	local function positions(): { Vector3 }
		local found: { Vector3 } = {}
		for _, builder in builders do
			table.insert(found, builder.position)
		end
		return found
	end
	advance(10)
	local arrived = spread_round(blueprint.position, positions(), 12)
	-- how far they go between picks, on average, near the end: they keep drifting rather than sit still
	advance((args.seconds or 90) - 15)
	local before = positions()
	advance(5)
	local after = positions()
	local drift = 0
	for index, point in after do
		drift += Vector3.new(point.X - before[index].X, 0, point.Z - before[index].Z).Magnitude
	end
	local assisting = 0
	for _, builder in builders do
		local order = builder.orders[1]
		if order ~= nil and order.kind == "assist" then
			assisting += 1
		end
	end
	local collider = unit_defs.get(blueprint.def_name).collider
	return {
		arrived = arrived,
		settled = spread_round(blueprint.position, after, 12),
		mean_drift_last_5s = round(drift / count, 2),
		still_assisting = `{assisting}/{count}`,
		blueprint_state = blueprint.state,
		blueprint_half_width = if collider.shape == "box" then collider.width / 2 else collider.radius,
		build_range = config.BUILD_RANGE,
	}
end

-- A gunship, `args.unit` or a Tyrannus, `args.count` of them (1), attacking an enemy that cannot die, `args.target` or
-- a Solar Collector, for `args.seconds` (60). From fifteen seconds in, once they are there: how near and far from it
-- they kept, how far round it the first went in all (so how many times it circled it), how slow it ever went, and the
-- damage done.
local function gunship_ring(args: { [string]: any }): Findings
	local unit = args.unit or "tyrannus"
	local target = unkillable(spawn(args.target or "solar_collector", ENEMY, 0, 0))
	local gunships: { Entity } = {}
	for index = 1, args.count or 1 do
		table.insert(gunships, spawn(unit, OWN, -90, (index - 1) * 8))
	end
	advance(config.TICK_DELTA)
	for _, gunship in gunships do
		orders.issue(gunship, { { kind = "attack", target_id = target.id } }, false, false)
	end
	local started = sim_time
	local nearest, furthest, slowest = math.huge, 0, math.huge
	local turned = 0
	local last_angle: number? = nil
	advance(args.seconds or 60, function()
		if sim_time - started < 15 then
			return
		end
		for _, gunship in gunships do
			local away = Vector3.new(gunship.position.X - target.position.X, 0, gunship.position.Z - target.position.Z)
			nearest = math.min(nearest, away.Magnitude)
			furthest = math.max(furthest, away.Magnitude)
		end
		local first = gunships[1]
		slowest = math.min(slowest, first.velocity.Magnitude)
		local angle = math.atan2(first.position.Z - target.position.Z, first.position.X - target.position.X)
		if last_angle ~= nil then
			turned += math.abs((angle - last_angle + math.pi) % (2 * math.pi) - math.pi)
		end
		last_angle = angle
	end)
	local positions: { Vector3 } = {}
	for _, gunship in gunships do
		table.insert(positions, gunship.position)
	end
	local def = unit_defs.get(unit)
	local ground_reach = 0
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			if weapon.target_layer ~= "air" then
				ground_reach = math.max(ground_reach, weapon.range)
			end
		end
	end
	return {
		distance = { round(nearest, 1), round(furthest, 1) },
		ground_reach = round(ground_reach, 1),
		circled_degrees = round(math.deg(turned), 0),
		slowest = round(slowest, 2),
		max_speed = round(def.max_speed :: number, 2),
		spread = if #positions > 1 then spread_round(target.position, positions, 8) else nil,
		damage_to_target = round(UNKILLABLE - target.health, 0),
	}
end

-- An anti-air launcher, `args.launcher` or a Thistle, and an enemy fighter flying straight past it, `args.pass` (50)
-- studs to one side, which is within its reach but further than `config.STEALTH_DETECTION_RANGE`: first a Nighthawk,
-- which is stealthy, then a Valiant, which is not. How many shots it fired at each.
local function stealth(args: { [string]: any }): Findings
	local launcher_def = args.launcher or "thistle"
	local pass = args.pass or 50
	local function shots_at(plane_def: string): number
		for _, entity in state.all() do
			state.mark_dead(entity)
		end
		advance(config.TICK_DELTA)
		local launcher = unkillable(spawn(launcher_def, OWN, 0, 0))
		local plane = unkillable(spawn(plane_def, ENEMY, -160, pass))
		advance(config.TICK_DELTA)
		orders.issue(plane, { { kind = "move", position = heightmap.ground_position(160, pass) } }, false, false)
		until_idle(plane, args.seconds or 25)
		local fired = 0
		local weapons = unit_defs.get(launcher_def).weapons
		if weapons ~= nil then
			for index in weapons do
				fired += combat.shots_of(launcher.id, index)
			end
		end
		return fired
	end
	return {
		pass = pass,
		detection_range = config.STEALTH_DETECTION_RANGE,
		launcher_reach = round(unit_defs.attack_range(unit_defs.get(launcher_def)) :: number, 1),
		shots_at_nighthawk = shots_at "nighthawk",
		shots_at_valiant = shots_at "valiant",
	}
end

-- Puts down `teams` AI opponents (2 by default) and lets them play for `seconds` (240), looking at every team each
-- `every` seconds (60): what it has of each def, finished or not, its incomes, how many of its economy's buildings stand
-- beside another of their kind, and whether it ever had two of any lab. `real_seconds` is how long it all took. `line`
-- ("bot" or "vehicle") makes every team build from that line's labs, and `enemy_air` puts that many aircraft of a team
-- of their own down, idle in a corner, for every AI to see.
local function ai_match(args: { [string]: any }): Findings
	local count = if typeof(args.teams) == "number" then args.teams else 2
	local seconds = if typeof(args.seconds) == "number" then args.seconds else 240
	local every = if typeof(args.every) == "number" then args.every else 60
	local clustered_defs = {
		"wind_turbine",
		"solar_collector",
		"advanced_solar_collector",
		"fusion_reactor",
		"energy_storage",
		"construction_turret",
	}
	local labs = {
		"bot_lab",
		"vehicle_lab",
		"advanced_bot_lab",
		"advanced_vehicle_lab",
		"air_lab",
		"shipyard",
		"hovercraft_platform",
	}

	local teams: { TeamId } = {}
	for index = 1, count do
		local team = ai.spawn_opponent(`AI {index}`)
		assert(team ~= nil, `there was no room for AI {index}'s commander`)
		table.insert(teams, team)
		if args.line == "bot" or args.line == "vehicle" then
			ai.set_line(team, args.line)
		end
	end
	if typeof(args.enemy_air) == "number" and args.enemy_air > 0 then
		local raiders = 99
		state.create_team(raiders)
		local half_x, half_z = heightmap.half_extents()
		for index = 1, args.enemy_air do
			unkillable(spawn("whirlwind", raiders, -half_x + 10 + index * 4, half_z - 10))
		end
	end

	local duplicate_labs: { string } = {}
	local function look(team: TeamId): Findings
		local counts: { [string]: number } = {}
		local mine: { Entity } = {}
		for _, entity in state.all() do
			if entity.alive and entity.team == team then
				counts[entity.def_name] = (counts[entity.def_name] or 0) + 1
				table.insert(mine, entity)
			end
		end
		for _, lab in labs do
			if (counts[lab] or 0) > 1 then
				table.insert(duplicate_labs, `team {team} had {counts[lab]} {lab}`)
			end
		end
		-- how many of each clustered def stand touching another of the same def
		local touching: { [string]: string } = {}
		for _, def_name in clustered_defs do
			local total, beside = 0, 0
			for _, entity in mine do
				if entity.def_name ~= def_name then
					continue
				end
				total += 1
				local half = unit_defs.footprint_half_extents(unit_defs.of(entity))
				for _, other in mine do
					if other ~= entity and other.def_name == def_name then
						local other_half = unit_defs.footprint_half_extents(unit_defs.of(other))
						local dx = math.abs(entity.position.X - other.position.X)
						local dz = math.abs(entity.position.Z - other.position.Z)
						if dx <= half.X + other_half.X + 0.5 and dz <= half.Y + other_half.Y + 0.5 then
							beside += 1
							break
						end
					end
				end
			end
			if total > 0 then
				touching[def_name] = `{beside}/{total}`
			end
		end
		local state_team = state.get_team(team) :: types.Team
		return {
			summary = ai.describe(team),
			metal_income = round(state_team.metal_income, 1),
			energy_income = round(state_team.energy_income, 1),
			counts = counts,
			beside_their_kind = touching,
		}
	end

	local started = os.clock()
	local snapshots: { Findings } = {}
	local elapsed = 0
	while elapsed < seconds do
		local span = math.min(every, seconds - elapsed)
		advance(span)
		elapsed += span
		local at: Findings = { at = elapsed }
		for _, team in teams do
			at[`team_{team}`] = look(team)
		end
		table.insert(snapshots, at)
	end
	return {
		snapshots = snapshots,
		duplicate_labs = duplicate_labs,
		real_seconds = round(os.clock() - started, 1),
	}
end

-- Puts down an AI opponent and `towers` (6) unkillable guard towers of an enemy team beside the metal spots nearest
-- its home past `from` (80) studs, and lets it play for `seconds` (480), looking once a second at how many of its
-- constructors stand within reach of a tower. `builder_seconds_in_reach` should stay near nothing and `lost` at 0.
local function ai_danger(args: { [string]: any }): Findings
	local geometry = require(ReplicatedStorage.Shared.geometry)
	local seconds = if typeof(args.seconds) == "number" then args.seconds else 480
	local tower_count = if typeof(args.towers) == "number" then args.towers else 6
	local from = if typeof(args.from) == "number" then args.from else 80
	local team = ai.spawn_opponent "AI"
	assert(team ~= nil, "there was no room for the AI's commander")
	local home = Vector3.zero
	for _, entity in state.all() do
		if entity.alive and entity.team == team and unit_defs.of(entity).nametag == true then
			home = entity.position
		end
	end
	local spots: { Vector3 } = {}
	for _, spot in metal_spots.all() do
		for _, position in spot.positions do
			if geometry.distance_2d(position, home) >= from then
				table.insert(spots, position)
			end
		end
	end
	table.sort(spots, function(a, b): boolean
		return geometry.distance_2d(a, home) < geometry.distance_2d(b, home)
	end)
	local enemy = 98
	state.create_team(enemy)
	local towers: { Entity } = {}
	for index = 1, math.min(tower_count, #spots) do
		local spot = spots[index]
		local toward = geometry.flatten(home - spot)
		local at = spot + (if toward.Magnitude > 1 then toward.Unit else Vector3.new(1, 0, 0)) * 8
		table.insert(towers, unkillable(spawn("guard", enemy, at.X, at.Z)))
	end
	local reach = (unit_defs.attack_range(unit_defs.get "guard") :: number) + 2

	local in_reach = 0
	local elapsed = 0
	local started = os.clock()
	while elapsed < seconds do
		advance(1)
		elapsed += 1
		for _, entity in state.all() do
			local def = unit_defs.of(entity)
			local options = def.build_options
			if
				entity.alive == false
				or entity.team ~= team
				or entity.kind ~= "unit"
				or def.nametag == true
				or options == nil
				or table.find(options, "metal_extractor") == nil
			then
				continue
			end
			for _, tower in towers do
				if geometry.distance_2d(entity.position, tower.position) <= reach then
					in_reach += 1
					break
				end
			end
		end
	end
	local counts: { [string]: number } = {}
	for _, entity in state.all() do
		if entity.alive and entity.team == team then
			counts[entity.def_name] = (counts[entity.def_name] or 0) + 1
		end
	end
	return {
		summary = ai.describe(team),
		towers = #towers,
		tower_reach = round(reach, 1),
		builder_seconds_in_reach = in_reach,
		counts = counts,
		real_seconds = round(os.clock() - started, 1),
	}
end

local TESTS: { [string]: (args: { [string]: any }) -> Findings } = {
	ai_danger = ai_danger,
	ai_match = ai_match,
	air_ring = air_ring,
	gunship_ring = gunship_ring,
	stealth = stealth,
	skins = skins_test,
	donut_state = donut_state,
	tutorial_boulder = tutorial_boulder,
	tutorial_victory = tutorial_victory,
	overlook = overlook,
	load_mission = load_mission,
	resource_sharing = resource_sharing,
	ally_griefing = ally_griefing,
	experience = experience,
	match_stats = match_stats_test,
	match = match_test,
	resource_bonus = resource_bonus,
	load_map = load_map,
	load_every_map = load_every_map,
	map = map,
	walk_orders = walk_orders,
	move_route = move_route,
	lab_exit = lab_exit,
	lab_orders = lab_orders,
	conditions = conditions,
	drone_stockpile = drone_stockpile,
	reclaimables = reclaimables,
	reclaim_income = reclaim_income,
	geothermal = geothermal,
	nuke_manual = nuke_manual,
	hit_control = hit_control,
	wing_edges = wing_edges,
	build_route = build_route,
	build_in_reach = build_in_reach,
	build_reach_edge = build_reach_edge,
	builder_blocked = builder_blocked,
	turret = turret,
	beam = beam,
	bombing = bombing,
	fighter = fighter,
	aa_missiles = aa_missiles,
	transport_pickup = transport_pickup,
	scavenger_hunt = scavenger_hunt,
	scavenger_opening = scavenger_opening,
	scavenger_endgame = scavenger_endgame,
	scavenger_stranded = scavenger_stranded,
	naval = naval,
	hovercraft = hovercraft,
	hover_reach = hover_reach,
}

-- The arguments the session was started with, if a Studio plugin started it with a table of them.
local function test_args(): { [string]: any }?
	if RunService:IsStudio() == false then
		return nil
	end
	-- the service is only there in Studio, so it is not asked for until now
	local ok, args = pcall(function()
		return game:GetService("StudioTestService"):GetTestArgs()
	end)
	if ok == false or typeof(args) ~= "table" or typeof(args.test) ~= "string" then
		return nil
	end
	return args
end

local function finish(result: Findings)
	game:GetService("StudioTestService"):EndTest(result)
end

-- Starts the test this session was started to run, if it was, and says whether it did: from then on the test is
-- what this session is for. `step` is one step of the simulation, which the test runs itself.
local function begin(step: (number) -> ()): boolean
	local args = test_args()
	if args == nil then
		return false
	end
	-- a test that hands in a match plays with the scavengers as the match has them
	if args.match == nil then
		scavengers.set_enabled(false)
	end

	if args.test == "benchmark" then
		task.spawn(function()
			local report = ""
			local ok, err = pcall(benchmark.run, function(text: string)
				report = text
			end)
			finish(if ok then { ok = true, report = report } else { ok = false, error = tostring(err) })
		end)
		return true
	end

	local test = TESTS[args.test]
	if test == nil then
		local names = {}
		for name in TESTS do
			table.insert(names, name)
		end
		table.insert(names, "benchmark")
		table.sort(names)
		finish({ ok = false, error = `no test "{args.test}"; there are {table.concat(names, ", ")}` })
		return true
	end

	if args.scenery ~= true then
		scenery.clear()
	end
	owning_clock = true
	step_simulation = step
	task.spawn(function()
		local ok, findings = pcall(test, args)
		if ok then
			findings.ok = true
			findings.sim_seconds = round(sim_time, 2)
			finish(findings)
		else
			finish({ ok = false, error = tostring(findings) })
		end
	end)
	return true
end

-- The match a test hands in the way a lobby would (`match`, as shared/game_modes.luau encodes one), for the game to
-- start with instead of its usual map, seed and scavengers; nil if it hands none in.
local function handed_match(): any?
	local args = test_args()
	if args == nil then
		return nil
	end
	return args.match
end

-- The map preset a test asked to be run on, or nil for the usual one. Read before the map is made.
local function preset(): string?
	local args = test_args()
	if args == nil or typeof(args.preset) ~= "string" then
		return nil
	end
	return args.preset
end

-- Whether a test is stepping the simulation itself, so that the usual loop must not.
local function owns_clock(): boolean
	return owning_clock
end

-- Whether this session was started to run a test. Read before the map is made.
local function requested(): boolean
	return test_args() ~= nil
end

return table.freeze({
	begin = begin,
	requested = requested,
	preset = preset,
	handed_match = handed_match,
	owns_clock = owns_clock,
})
