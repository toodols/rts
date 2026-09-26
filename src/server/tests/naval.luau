--!strict
-- Tests of fighting on and under the water, and of hovercraft, which ride it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local passability = require(ReplicatedStorage.Shared.passability)

local orders = require(ServerScriptService.Server.orders)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local ENEMY = harness.ENEMY
local NOCOST = harness.NOCOST
local advance = harness.advance
local now = harness.now
local round = harness.round
local spawn = harness.spawn
local spawn_resting = harness.spawn_resting
local unkillable = harness.unkillable
local damage_to = harness.damage_to
local clear_world = harness.clear_world
local with_switch = harness.with_switch
local in_flight = harness.in_flight

type Entity = types.Entity
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- How far a hovercraft's underside may be off the water's surface as it rides it.
local SURFACE_SLACK = 0.5
-- A map with open sea, and beaches round it.
local SEA_MAP = { preset = "islands" }
-- A map with open sea and wide dry land, for what is fired from the one at the other.
local CONTINENTS_MAP = { preset = "continents" }
-- A nuke launched from under the water should be seen first within this many studs of the surface, having only just
-- left the submarine, climb at least this far above the water, and come down within this many studs of its mark.
local LAUNCH_SURFACE_SLACK = 10
local LAUNCH_MIN_CLIMB = 100
local LAUNCH_LANDING_SLACK = 10

-- A match of `seconds` of a `shooter_def` at `shooter_at` against a `target_def` at `target_at` that it cannot kill,
-- each resting where it is, the shooter turned `turned` radians off facing the target and the target facing the way
-- `target_facing` gives (straight ahead along z by default): how much damage the target took, how much the shooter
-- took, how many projectiles and how many torpedoes the shooter let go, whether the shooter was under the water, and
-- how far the target's top and bottom are from the water's surface. `keeps_to_the_water` says whether it kept to what
-- can be fired where: nothing but a torpedo at something wholly under the water or from under it, and no torpedo at
-- something out of it.
local function water_duel(
	shooter_def: string,
	target_def: string,
	target_at: Vector3,
	shooter_at: Vector3,
	seconds: number,
	turned: number?,
	target_facing: number?
): Findings
	local target = unkillable(spawn_resting(target_def, ENEMY, target_at.X, target_at.Z))
	target.facing = target_facing or 0
	-- the target may shoot back, and the shooter has to last the whole match for its count of shots to mean anything
	local shooter = unkillable(spawn_resting(shooter_def, OWN, shooter_at.X, shooter_at.Z))
	shooter.facing = math.atan2(target_at.X - shooter_at.X, target_at.Z - shooter_at.Z) + (turned or 0)
	local seen: { [number]: boolean } = {}
	local shots, torpedoes = 0, 0
	advance(seconds, function()
		for _, projectile in in_flight() do
			if projectile.owner_id == shooter.id and seen[projectile.id] == nil then
				seen[projectile.id] = true
				shots += 1
				if projectile.delivery.kind == "torpedo" then
					torpedoes += 1
				end
			end
		end
	end)
	local half = unit_defs.collider_height(unit_defs.get(target_def)) / 2
	local top = target.position.Y + half - ground_levels.WATER_LEVEL
	local bottom = target.position.Y - half - ground_levels.WATER_LEVEL
	local shooter_under = unit_defs.submerged(unit_defs.get(shooter_def), shooter.position)
	local target_under = unit_defs.submerged(unit_defs.get(target_def), target.position)
	local target_in_water = unit_defs.in_water(unit_defs.get(target_def), target.position)
	local findings: Findings = {
		damage_to_target = round(damage_to(target), 0),
		damage_to_shooter = round(damage_to(shooter), 0),
		shots = shots,
		torpedoes = torpedoes,
		shooter_under_water = shooter_under,
		target_top_above_water = round(top, 2),
		target_bottom_above_water = round(bottom, 2),
	}
	findings.keeps_to_the_water = (target_under == false or shots == torpedoes)
		and (shooter_under == false or shots == torpedoes)
		and (target_in_water or torpedoes == 0)
	clear_world()
	return findings
end

-- Submarines and torpedoes. Several matches, each `args.seconds` (15 by default) long, of a shooter against
-- something at `distance` that it cannot kill, all out in deep water unless they are said to be on land. Nothing but a
-- torpedo should be aimed at a submarine or at anything else wholly under the water, a torpedo at nothing that is not
-- in the water, and nothing but a torpedo should be fired from under the water. A Buccaneer's depth charges and an
-- Orca's torpedoes should hurt what they are fired at, whether a ship, a submarine or a commander on the sea floor;
-- a Riptide, which has no torpedoes, should not fire at a submarine or a commander on the sea floor at all.
-- Dry land with deep open water 30 studs off it, one way or another, and which way that is; nil if the map has none.
local function shore_by_deep_water(): (Vector3?, Vector3)
	local shore_offset = Vector3.zero
	local shore = harness.find_spot(function(x: number, z: number): boolean
		if heightmap.height_at(x, z) < ground_levels.WATER_LEVEL + 1 then
			return false
		end
		for index = 0, 7 do
			local angle = index * math.pi / 4
			local offset = Vector3.new(math.cos(angle) * 30, 0, math.sin(angle) * 30)
			if harness.deep_all_round(x + offset.X, z + offset.Z, 6, 8) then
				shore_offset = offset
				return true
			end
		end
		return false
	end)
	return shore, shore_offset
end

local function naval(args: Args): Findings
	local seconds = args.seconds or 15
	local sea = harness.open_sea()
	local shore, shore_offset = shore_by_deep_water()

	local function duel(shooter_def: string, target_def: string, target_at: Vector3, shooter_at: Vector3): Findings
		return water_duel(shooter_def, target_def, target_at, shooter_at, seconds)
	end

	local off = Vector3.new(30, 0, 0)
	local findings: Findings = {
		sea = { x = sea.X, z = sea.Z, depth = round(heightmap.water_depth(sea.X, sea.Z), 1) },
		buccaneer_at_orca = duel("buccaneer", "orca", sea, sea + off),
		orca_at_buccaneer = duel("orca", "buccaneer", sea, sea + off),
		riptide_at_orca = duel("riptide", "orca", sea, sea + off),
		orca_at_commander_on_sea_floor = duel("orca", "commander", sea, sea + off),
		riptide_at_commander_on_sea_floor = duel("riptide", "commander", sea, sea + off),
		commander_on_sea_floor_at_riptide = duel("commander", "riptide", sea, sea + off),
	}
	if shore ~= nil then
		findings.orca_at_commander_on_land = duel("orca", "commander", shore, shore + shore_offset)
	end
	local all_kept = true
	for _, found in findings do
		if typeof(found) == "table" and found.keeps_to_the_water == false then
			all_kept = false
		end
	end
	findings.pass = all_kept
		and findings.buccaneer_at_orca.damage_to_target > 0
		and findings.orca_at_buccaneer.damage_to_target > 0
		and findings.riptide_at_orca.shots == 0
		and findings.orca_at_commander_on_sea_floor.damage_to_target > 0
		and findings.riptide_at_commander_on_sea_floor.shots == 0
	return findings
end

-- Fixed forward weapons and depth charges, out in deep water, each match `args.seconds` (15 by default) long. An Orca
-- fires its torpedoes only into the 30 degree cone ahead of it: at a Buccaneer dead ahead and 12 degrees off it
-- should fire, at 20 and 90 degrees off it should not. A Buccaneer's depth charges, dropped from its deck, must hurt
-- the Orca and never the Buccaneer itself; the Orca faces away, so nothing else can hurt it. The Buccaneer's laser
-- spends energy a shot, which a team in a test has none of, so the matches are played with nocost on.
local function naval_arcs(args: Args): Findings
	local seconds = args.seconds or 15
	local sea = harness.open_sea()
	local off = Vector3.new(30, 0, 0)
	local findings: Findings = {}
	with_switch(NOCOST, true, function()
		findings = {
			orca_ahead = water_duel("orca", "buccaneer", sea, sea + off, seconds, 0, 0),
			orca_12_degrees_off = water_duel("orca", "buccaneer", sea, sea + off, seconds, math.rad(12), 0),
			orca_20_degrees_off = water_duel("orca", "buccaneer", sea, sea + off, seconds, math.rad(20), 0),
			orca_90_degrees_off = water_duel("orca", "buccaneer", sea, sea + off, seconds, math.rad(90), 0),
			-- the Orca faces away from the Buccaneer, along -x, so it cannot fire back
			buccaneer_at_orca = water_duel("buccaneer", "orca", sea, sea + off, seconds, 0, -math.pi / 2),
		}
	end)
	findings.pass = findings.orca_ahead.shots > 0
		and findings.orca_12_degrees_off.shots > 0
		and findings.orca_20_degrees_off.shots == 0
		and findings.orca_90_degrees_off.shots == 0
		and findings.buccaneer_at_orca.damage_to_target > 0
		and findings.buccaneer_at_orca.damage_to_shooter == 0
	return findings
end

-- Hovercraft. A Goon, or `args.unit`, is sent from dry land down a beach out onto deep water and back, and then out
-- to open sea, and must get there every time, riding the water's surface all the way and taking no harm from it.
-- Then matches as `naval` has them, each `args.seconds` (15 by default) long, out in deep water: an Orca's torpedoes
-- must never be aimed at a hovercraft, a Buccaneer's depth charges neither, while its laser hurts one, and a Halberd
-- must be able to shoot a ship, as an Orca's torpedoes can. The lasers spend energy a shot, which a team in a test has
-- none of, so the matches are played with nocost on.
local function hovercraft(args: Args): Findings
	local seconds = args.seconds or 15
	local sea = harness.open_sea()
	local traveller = args.unit or "goon"
	local def = unit_defs.get(traveller)
	-- dry land from which a straight run of ground not too steep for it goes down a beach into deep water, where
	-- `beach_end` is
	local beach_end = Vector3.zero
	local shore = harness.find_spot(function(x: number, z: number): boolean
		if
			heightmap.height_at(x, z) < ground_levels.WATER_LEVEL + 1
			or passability.passable_at(def.footing.class, x, z) == false
		then
			return false
		end
		for index = 0, 7 do
			local angle = index * math.pi / 4
			local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
			for distance = 2, 60, 2 do
				local point = Vector3.new(x, 0, z) + direction * distance
				if passability.passable_at(def.footing.class, point.X, point.Z) == false then
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
	local goon = unkillable(spawn_resting(traveller, OWN, shore.X, shore.Z))
	advance(tick_rate.TICK_DELTA)
	local function go(to: Vector3): Findings
		local destination = surface.position(def, to.X, to.Z)
		local route, searched = pathfinder.route(def, goon.position, destination, 8000)
		orders.issue(goon, route, false, false)
		local started = now()
		-- how low its underside came over the water, and how far from the surface it ever was there
		local lowest_over_water = math.huge
		local off_surface = 0
		local arrived = harness.until_idle(goon, args.travel_seconds or 90, function()
			local at = goon.position
			if heightmap.water_depth(at.X, at.Z) > 0 then
				local bottom = at.Y - unit_defs.collider_height(def) / 2
				lowest_over_water = math.min(lowest_over_water, bottom - ground_levels.WATER_LEVEL)
				off_surface = math.max(off_surface, math.abs(bottom - surface.height(def, at.X, at.Z)))
			end
		end)
		local offset = destination - goon.position
		return {
			passable_from = passability.passable_at(def.footing.class, goon.position.X, goon.position.Z),
			passable_to = passability.passable_at(def.footing.class, to.X, to.Z),
			searched = searched,
			waypoints = #route,
			arrived = arrived,
			seconds = round(now() - started, 2),
			left_to_go = round(Vector3.new(offset.X, 0, offset.Z).Magnitude, 1),
			lowest_over_water = if lowest_over_water == math.huge
				then "never over water"
				else round(lowest_over_water, 2),
			off_surface = round(off_surface, 3),
			rode_the_surface = off_surface <= SURFACE_SLACK,
			in_water = unit_defs.in_water(def, goon.position),
			submerged = unit_defs.submerged(def, goon.position),
		}
	end
	local findings: Findings = {
		sea = { x = sea.X, z = sea.Z, depth = round(heightmap.water_depth(sea.X, sea.Z), 1) },
		land = { x = shore.X, z = shore.Z, height = round(heightmap.height_at(shore.X, shore.Z), 1) },
		beach_end = {
			x = beach_end.X,
			z = beach_end.Z,
			depth = round(heightmap.water_depth(beach_end.X, beach_end.Z), 1),
		},
		off_the_beach = go(beach_end),
		back_ashore = go(shore),
		out_to_open_sea = go(sea),
	}
	findings.goon_damage_from_travel = round(damage_to(goon), 0)
	clear_world()

	local off = Vector3.new(30, 0, 0)
	with_switch(NOCOST, true, function()
		findings.orca_at_goon = water_duel("orca", "goon", sea, sea + off, seconds)
		findings.buccaneer_at_halberd = water_duel("buccaneer", "halberd", sea, sea + off, seconds)
		-- inside the Halberd's reach, 300 elmos
		findings.halberd_at_riptide = water_duel("halberd", "riptide", sea, sea + Vector3.new(20, 0, 0), seconds)
		findings.orca_at_riptide = water_duel("orca", "riptide", sea, sea + off, seconds)
	end)
	local trips_ok = true
	for _, trip in { findings.off_the_beach, findings.back_ashore, findings.out_to_open_sea } do
		trips_ok = trips_ok and trip.arrived and trip.rode_the_surface and trip.submerged == false
	end
	findings.pass = trips_ok
		and findings.goon_damage_from_travel == 0
		and findings.orca_at_goon.torpedoes == 0
		and findings.buccaneer_at_halberd.torpedoes == 0
		and findings.buccaneer_at_halberd.damage_to_target > 0
		and findings.halberd_at_riptide.damage_to_target > 0
		and findings.orca_at_riptide.damage_to_target > 0
	return findings
end

-- The Sea Dragon (armseadragon), a nuclear submarine, resting under the water in open deep sea with a nuke ready: it
-- holds it with nothing to do and through a plain attack order, and launches it on a launch (D, `Order.launch`) at a
-- point on land, from under the water (`Weapon.launches_underwater`). The missile has to climb out of the sea rather
-- than go off on the surface over the submarine, and come down on the point, hurting what is there and not the
-- submarine. Then the Thor's EMP missile, which a plain attack must not fire either and a launch must. Played on a map
-- with open sea and dry land.
local function sea_dragon(args: Args): Findings
	-- deep enough to go under in, with room to lie in it
	local deepest = 0
	local sea = harness.find_spot(function(x: number, z: number): boolean
		deepest = math.max(deepest, heightmap.water_depth(x, z))
		return harness.deep_all_round(x, z, args.depth or 7, args.room or 20)
	end)
	assert(sea ~= nil, `no open deep water on this map; the deepest is {round(deepest, 1)}`)
	local sea_spot = sea :: Vector3
	-- dry land well clear of the blast, which is about 40 studs across
	local land = harness.find_spot(function(x: number, z: number): boolean
		return heightmap.height_at(x, z) > ground_levels.WATER_LEVEL + 1
			and geometry.distance_2d(Vector3.new(x, 0, z), sea_spot) > (args.clear or 80)
	end)
	assert(land ~= nil, `no dry land on this map; the sea is at {sea_spot}`)
	local land_spot = land :: Vector3

	local findings: Findings = {}
	-- the next missile is paid for as it is built, and what it costs is beside the point
	with_switch(NOCOST, true, function()
		local def = unit_defs.get "sea_dragon"
		local sub = unkillable(spawn_resting("sea_dragon", OWN, sea_spot.X, sea_spot.Z))
		sub.weapon_stockpiles[2].held = 1
		local target = unkillable(spawn("grunt", ENEMY, land_spot.X, land_spot.Z))
		advance(3)
		local held_idle = sub.weapon_stockpiles[2].held
		orders.issue(sub, { { kind = "attack", target_id = target.id } }, false, false)
		advance(3)
		local held_on_attack = sub.weapon_stockpiles[2].held
		local sub_top = sub.position.Y + unit_defs.collider_height(def) / 2

		local point = heightmap.ground_position(land_spot.X, land_spot.Z)
		orders.issue(sub, { { kind = "attack_ground", position = point, launch = true } }, false, false)
		local seen = false
		local first_y: number? = nil
		local peak = -math.huge
		local last: Vector3? = nil
		advance(args.seconds or 60, function()
			for _, projectile in in_flight() do
				if projectile.owner_id == sub.id and projectile.nuke ~= nil then
					seen = true
					local at = projectile.flight.position
					first_y = first_y or at.Y
					peak = math.max(peak, at.Y)
					last = at
				end
			end
		end)
		findings = {
			sea = { x = sea_spot.X, z = sea_spot.Z, depth = round(heightmap.water_depth(sea_spot.X, sea_spot.Z), 1) },
			distance = round(geometry.distance_2d(sea_spot, land_spot), 0),
			submerged = sub_top < ground_levels.WATER_LEVEL,
			held_with_no_order = held_idle == 1,
			held_on_plain_attack = held_on_attack == 1,
			launched = seen and sub.weapon_stockpiles[2].held == 0,
			-- how high the missile was at the end of its first tick, above the water's surface
			first_seen_at = if first_y ~= nil then round((first_y :: number) - ground_levels.WATER_LEVEL, 1) else -1,
			climbed_out = round(peak - ground_levels.WATER_LEVEL, 0),
			came_down_off_by = if last ~= nil then round(geometry.distance_2d(last :: Vector3, point), 1) else -1,
			damage_to_target = round(damage_to(target), 0),
			damage_to_sub = round(damage_to(sub), 0),
			order_done = #sub.orders == 0,
		}
		clear_world()

		local thor = unkillable(spawn("thor", OWN, land_spot.X, land_spot.Z))
		thor.weapon_stockpiles[2].held = 1
		local enemy: Entity = unkillable(spawn("grunt", ENEMY, land_spot.X + 40, land_spot.Z))
		orders.issue(thor, { { kind = "attack", target_id = enemy.id } }, false, false)
		advance(4)
		local thor_held = thor.weapon_stockpiles[2].held
		orders.issue(thor, { { kind = "attack", target_id = enemy.id, launch = true } }, false, false)
		advance(4)
		findings.thor = {
			held_on_plain_attack = thor_held == 1,
			launched_on_launch = thor.weapon_stockpiles[2].held == 0,
		}
		clear_world()
	end)
	findings.pass = findings.submerged
		and findings.held_with_no_order
		and findings.held_on_plain_attack
		and findings.launched
		and math.abs(findings.first_seen_at) <= LAUNCH_SURFACE_SLACK
		and findings.climbed_out >= LAUNCH_MIN_CLIMB
		and findings.came_down_off_by >= 0
		and findings.came_down_off_by <= LAUNCH_LANDING_SLACK
		and findings.damage_to_target > 0
		and findings.damage_to_sub == 0
		and findings.order_done
		and findings.thor.held_on_plain_attack
		and findings.thor.launched_on_launch
	return findings
end

-- A Buccaneer, a ship, left on dry land beside deep water (as a transport or a map edit might leave one) and sent out
-- onto the water: it should make its way off the land, as anything standing where it cannot may, and be afloat within
-- `args.seconds` (15 by default).
local function ship_off_land(args: Args): Findings
	local shore, offset = shore_by_deep_water()
	if shore == nil then
		return { pass = false, shore = "none" }
	end
	local ship = spawn_resting("buccaneer", OWN, shore.X, shore.Z)
	local def = ship.def
	local sea = shore + offset
	orders.issue(
		ship,
		{ { kind = "move", position = surface.position(def, sea.X, sea.Z), target_id = nil } },
		false,
		false
	)
	advance(args.seconds or 15)
	local depth = heightmap.water_depth(ship.position.X, ship.position.Z)
	local findings: Findings = {
		moved = round(geometry.distance_2d(ship.position, shore), 1),
		depth = round(depth, 1),
		afloat = depth >= def.footing.min_depth,
	}
	findings.pass = findings.afloat
	return findings
end

local TESTS: { [string]: Test } = {
	naval = { run = naval, defaults = SEA_MAP },
	naval_arcs = { run = naval_arcs, defaults = SEA_MAP },
	hovercraft = { run = hovercraft, defaults = SEA_MAP },
	sea_dragon = { run = sea_dragon, defaults = CONTINENTS_MAP },
	ship_off_land = { run = ship_off_land, defaults = SEA_MAP },
}

return table.freeze(TESTS)
