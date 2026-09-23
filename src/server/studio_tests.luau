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

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local StudioTestService = game:GetService "StudioTestService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local starts = require(ReplicatedStorage.Shared.starts)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local map_state = require(ReplicatedStorage.Shared.map_state)
local map_presets = require(ReplicatedStorage.Shared.map_presets)

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
			bar_seconds = round(def.buildpower_cost / buildpower, 2),
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

-- Geothermal vents and what stands on them (`geo_spots`, `placement`, `construction`, `drones`). How many vents the
-- map has and whether each has its twin across the middle. With nocost on: a Construction Bot, or `args.unit`, puts a
-- Geothermal Powerplant on a vent, and what that adds to the team's energy income; whether one can go anywhere off a
-- vent; an Advanced Construction Bot puts an Advanced Geothermal Powerplant over it, and whether the plain one went.
-- Then a Rampart on the vent's twin: its drones, and whether it shoots down a nuke launched at something beside it.
local function geothermal(args: { [string]: any }): Findings
	local geo_spots = require(ReplicatedStorage.Shared.geo_spots)
	local placement = require(script.Parent.placement)
	local nocost = require(script.Parent.nocost)
	local vents = geo_spots.all()
	local function twin_of(at: Vector3): Vector3?
		for _, other in vents do
			if math.abs(other.center.X + at.X) < 0.01 and math.abs(other.center.Z + at.Z) < 0.01 then
				return other.center
			end
		end
		return nil
	end
	local unpaired = 0
	for _, vent in vents do
		if twin_of(vent.center) == nil then
			unpaired += 1
		end
	end
	local findings: Findings = { vents = #vents, unpaired = unpaired }
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

	-- a Rampart on the vent's twin, with an interceptor ready, and a nuke launched at a grunt beside it
	local other = twin_of(vent) or vents[2].center
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
	local silo_def = unit_defs.get "apocalypse"
	local silo_x = if rampart_at.X > 0 then rampart_at.X - 250 else rampart_at.X + 250
	local silo = unkillable(
		state.create_entity(
			"apocalypse",
			ENEMY,
			unit_defs.surface_position(silo_def, silo_x, rampart_at.Z)
				+ Vector3.new(0, unit_defs.collider_height(silo_def) / 2, 0),
			0,
			"active"
		)
	)
	advance(config.TICK_DELTA)
	silo.weapon_stockpiles[1] = 1
	orders.issue(silo, { { kind = "attack", position = nil, target_id = mark.id } }, false, false)
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
		results[name] = {
			loaded = ok,
			error = err,
			seconds = round(os.clock() - began, 2),
			size = `{half_x * 2}x{half_z * 2}`,
			metal_spots = #metal_spots.all(),
		}
	end
	return { maps = results }
end

local TESTS: { [string]: (args: { [string]: any }) -> Findings } = {
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
	geothermal = geothermal,
	nuke_manual = nuke_manual,
	hit_control = hit_control,
	build_route = build_route,
	turret = turret,
	beam = beam,
	bombing = bombing,
	fighter = fighter,
	transport_pickup = transport_pickup,
	scavenger_hunt = scavenger_hunt,
	naval = naval,
}

-- The arguments the session was started with, if a Studio plugin started it with a table of them.
local function test_args(): { [string]: any }?
	if RunService:IsStudio() == false then
		return nil
	end
	local ok, args = pcall(StudioTestService.GetTestArgs, StudioTestService)
	if ok == false or typeof(args) ~= "table" or typeof(args.test) ~= "string" then
		return nil
	end
	return args
end

local function finish(result: Findings)
	StudioTestService:EndTest(result)
end

-- Starts the test this session was started to run, if it was, and says whether it did: from then on the test is
-- what this session is for. `step` is one step of the simulation, which the test runs itself.
local function begin(step: (number) -> ()): boolean
	local args = test_args()
	if args == nil then
		return false
	end
	scavengers.set_enabled(false)

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

return table.freeze({
	begin = begin,
	preset = preset,
	owns_clock = owns_clock,
})
