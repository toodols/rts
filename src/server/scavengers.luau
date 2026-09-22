-- The scavengers gamemode. Every few minutes a beacon appears somewhere on the map, and for as long as it
-- stands it keeps producing hostile units and defences around itself. The units scatter across the map and
-- hunt: anything of a player's that one notices, and has a straight run at, it attacks.
--
-- The scavengers are a team of their own (`config.SCAVENGER_TEAM`), so everything `combat` already knows
-- about enemies applies to them without a special case: defences shoot whatever comes into range, and a
-- player's units shoot them back. Only the beacon's schedule and what the units decide to do live here.
--
-- A unit goes by a "straight run", a line across ground it can stand on (`has_direct_path`), whenever it has one,
-- because that is nearly free. Only when it has none does it ask `pathfinder` for a route round whatever is in the
-- way, which costs anything from a millisecond to a good deal more, so there is a limit on how many are asked for
-- and how far each may search, and a unit that is refused waits before it tries again.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local passability = require(ReplicatedStorage.Shared.passability)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

local state = require(script.Parent.state)
local orders = require(script.Parent.orders)
local combat = require(script.Parent.combat)
local movement = require(script.Parent.movement)
local placement = require(script.Parent.placement)
local sight = require(script.Parent.sight)

type Entity = types.Entity
type EntityDef = types.EntityDef
type EntityId = types.EntityId
type Order = types.Order
type Path = pathfinder.Path
type Weapon = types.Weapon

-- One thing a beacon can produce. Whether it is a unit or a defence is the def's own kind, and when it starts
-- to be produced is up to its difficulty and how far the game has got: see `difficulty_of`.
type Spawn = {
	def_name: string,
	weight: number,
	-- made by a beacon that floats on the sea, and by no other; everything else is made by a land one
	sea: boolean?,
}

-- Units and defences are made on separate clocks, so that a beacon ringed with all the defences it will take
-- goes on making units.
type Beacon = {
	next_unit_at: number,
	next_defense_at: number,
	-- whether it floats on the sea, and makes ships, or stands on the land
	sea: boolean,
}

-- What a scavenger unit remembers between thoughts.
type Brain = {
	next_think: number,
	last_position: Vector3,
	-- seconds it has been trying to go somewhere and getting nowhere
	stuck_for: number,
	-- it will not go hunting before this time, so that a chase it could not finish is not begun again at once
	ignore_until: number,
	-- whether it has done the first thing a new unit does, which is to get clear of the others
	scattered: boolean,
	-- whether the order it is on is one it gave itself to go after something
	hunting: boolean,
	-- whether the order it is on is one it gave itself to go looking for something far off
	seeking: boolean,
	-- it will not ask for another route before this time
	next_path_at: number,
	-- the target it has a route to, where that target was when the route was made, and until when the route is
	-- left alone
	route_target: EntityId?,
	route_anchor: Vector3?,
	route_until: number,
	-- a target it found no route to, and until when it is not tried for again
	avoid_target: EntityId?,
	avoid_until: number,
}

type Spot = {
	position: Vector3,
	facing: number,
}

-- What the client is told: the scavengers' budget, which is the difficulty a player is up against, in this
-- attribute of Workspace, and nothing at all while the gamemode is off, which is how the client knows whether to
-- show it. It is rounded to two significant figures, so it changes every twenty seconds or so at most rather
-- than every tick.
local SHOWN_DIGITS = 2
local DIFFICULTY_ATTRIBUTE = "scavenger_difficulty"

local BEACON_DEF = "scavenger_beacon"
local SEA_BEACON_DEF = "scavenger_sea_beacon"
local BEACON_ATTEMPTS = 40
local BEACON_RETRY_DELAY = 10

-- Units appear this far from the middle of a beacon, and defences a little further out, so that a defence
-- never boxes the beacon's own units in. Rings then widen by SPAWN_RING_STEP until something fits.
local UNIT_RING_START = 12
local DEFENSE_RING_START = 16
local SPAWN_RING_STEP = 5
local SPAWN_RINGS = 8
-- A defence counts toward a beacon's limit when it stands this close to it.
local DEFENSE_SCAN_RADIUS = 60

-- What a beacon can make is worked out from the defs, in `build_roster` below, and is everything a player can build
-- that fights, so a new unit is in it without being added. A thing's weight is this over the square root of its
-- difficulty, so what is cheap is made more often than what is dear without the dear ever quite being left out.
local ROSTER_WEIGHT = 12

-- Fodder: what is worth less than this share of the budget is not made while there is anything stronger that fits. So
-- the easiest things go first as the budget grows and, once it is high enough, they stop altogether and all that is
-- made is the hardest of what the roster has.
local FODDER_SHARE = 0.04

-- When the units or defences are at their limit, something new retires the weakest only if it is at least this
-- many times as hard, so what is out there stays a spread of easy and hard rather than all of the newest.
local UPGRADE_FACTOR = 2

-- A beacon site needs room to move: this many of the 8 directions round it have to be open for this far, or
-- whatever it makes would be stranded on the spot it appeared. It is short enough for a small island.
local BEACON_OPEN_DIRECTIONS = 3
local BEACON_PROBE_LENGTH = 40
local BEACON_PROBE_DEF = "grunt"
local SEA_BEACON_PROBE_DEF = "supporter"

-- How often a unit makes up its mind, and how far it has to get in that time, while it has somewhere to be,
-- to count as getting anywhere. Failing for STUCK_LIMIT seconds it gives up on where it was going.
local THINK_INTERVAL = 1
local STUCK_DISTANCE = 1
local STUCK_LIMIT = 3
local STUCK_IGNORE_TIME = 8

-- A path is walked in steps this long, looking for ground the unit cannot stand on.
local PATH_SAMPLE_STEP = 4
-- Tries at a long wander, and then as many at a short one, for a unit that is on ground with little room.
local ROAM_ATTEMPTS = 8
local ROAM_SHORT_MIN = 10
-- How many of the nearest things a unit notices it checks for a straight run at before giving up.
local TARGET_PATH_CHECKS = 5
-- A new unit heads off away from its beacon by up to this far either side of straight out, and leaves the
-- hunting alone for this long, so that a wave does not stay bunched on the spot it appeared.
local SCATTER_FAN = math.pi / 3
local SCATTER_TIME = 5
-- A hunter walks to a spot of its own on a ring round its target, spread over this much of the ring on the
-- side it comes from, and counts as there when it is this close. The spot comes from its id, so it stays the same
-- from one moment to the next, and different ids fall in different places.
local SLOT_SPREAD = math.pi
local SLOT_ARRIVE_DISTANCE = 4
local SLOT_ID_STRIDE = 0.618034
-- Routes. Only this many are asked for in a step, and none may search more than this many cells, which is
-- about twenty milliseconds at the worst. A route the search is cut off from still leads part of the way, and a unit
-- that is seeking asks again from where it gets to. A route is trusted for ROUTE_HOLD seconds, which is long enough to walk a good
-- way round, and is redone before that only if its target has moved further than ROUTE_TARGET_DRIFT from where it
-- was. A unit waits ROUTE_COOLDOWN seconds between one route and the next, PATH_RETRY_DELAY if it was refused or
-- let down, and gives up on a target it found no way to for AVOID_TIME.
local PATHS_PER_TICK = 1
local PATH_MAX_EXPANSIONS = 2500
local ROUTE_HOLD = 30
local ROUTE_COOLDOWN = 5
local ROUTE_TARGET_DRIFT = 40
local PATH_RETRY_DELAY = 10
local AVOID_TIME = 30
-- Seeking. A unit that is looking for something far off goes to a staging spot this share of the detection
-- range from it, close enough that hunting takes over from there. A route that ends less than SEEK_MIN_PROGRESS
-- nearer to it than the unit already is has got nowhere, and counts as no way there.
local SEEK_STAGE_SHARE = 0.8
local SEEK_MIN_PROGRESS = 30
-- How many places on the map a stranded unit tries for a route to.
local ROAM_ROUTE_TRIES = 6
-- Close in to a little inside the nominal range, the same margin `orders` uses when it closes on a target, so
-- that "can it get within range" is asked of the spot it would actually stop at.
local RANGE_MARGIN = 0.85

local rng = Random.new()
local clock = 0
-- Added to the clock for the game's progress alone, so that progress can be set without moving the clock the
-- schedules run on.
local progress_offset = 0
local enabled = config.SCAVENGERS_ENABLED
local next_beacon_at = 0
local beacons: { [EntityId]: Beacon } = {}
local brains: { [EntityId]: Brain } = {}
-- How many more routes this step may ask for.
local paths_left = 0

local function is_scavenger(entity: Entity): boolean
	return entity.team == config.SCAVENGER_TEAM
end

local function is_beacon(entity: Entity): boolean
	return entity.def_name == BEACON_DEF or entity.def_name == SEA_BEACON_DEF
end

-- The weapon a unit's willingness to hunt is judged by: its own, or its first turret's.
local function main_weapon(def: EntityDef): Weapon?
	if def.weapon ~= nil then
		return def.weapon
	end
	if def.turrets ~= nil and #def.turrets > 0 then
		return def.turrets[1].weapon
	end
	-- a carrier has nothing of its own, but its drones do
	if def.carrier ~= nil then
		return unit_defs.get(def.carrier.drone).weapon
	end
	return nil
end

-- How far a unit reaches to fight: its longest weapon, or, for a carrier with none, how far out its drones go.
local function reach_of(def: EntityDef): number?
	local reach = unit_defs.attack_range(def)
	if reach == nil and def.carrier ~= nil then
		return def.carrier.engage_range
	end
	return reach
end

-- How far the game has got, from 0 to 1, rising steadily over `config.SCAVENGER_GAME_LENGTH` seconds. Nothing
-- the scavengers do is decided by anything else: beacons wait for it, and it is what their budget grows with.
local function progress(): number
	return math.clamp((clock + progress_offset) / config.SCAVENGER_GAME_LENGTH, 0, 1)
end

-- How hard something is to face, for now just what it cost: its metal and its energy over 60. It is only a
-- stand-in for a better judgement, so it lives in this one function.
local function difficulty_of(def_name: string): number
	local def = unit_defs.get(def_name)
	return (def.metal_cost + def.energy_cost) / 60
end

-- Whether every weapon it has can only be turned on aircraft.
local function is_anti_air_only(def: EntityDef): boolean
	local weapon = main_weapon(def)
	if weapon == nil then
		return false
	end
	if weapon.target_layer ~= "air" then
		return false
	end
	if def.turrets ~= nil then
		for _, turret in def.turrets do
			if turret.weapon.target_layer ~= "air" then
				return false
			end
		end
	end
	return true
end

-- Everything a player can build that fights, which is everything the scavengers can field: what is listed among
-- what some builder or factory makes, has a weapon or drones to fight with, and is not itself a drone. A beacon on
-- the sea makes what floats, and any other makes the rest. The list is sorted so that it is the same every time.
local function build_roster(): { Spawn }
	local buildable: { [string]: boolean } = {}
	for _, def in unit_defs.defs do
		if def.build_options ~= nil then
			for _, name in def.build_options do
				buildable[name] = true
			end
		end
	end

	local roster: { Spawn } = {}
	for name, def in unit_defs.defs do
		if buildable[name] == true and def.drone ~= true and main_weapon(def) ~= nil then
			table.insert(roster, {
				def_name = name,
				weight = ROSTER_WEIGHT / math.sqrt(difficulty_of(name)),
				sea = def.min_water_depth ~= nil,
			})
		end
	end
	table.sort(roster, function(a: Spawn, b: Spawn): boolean
		return a.def_name < b.def_name
	end)
	return roster
end

local SPAWNS: { Spawn } = build_roster()

-- The hardest difficulty in the roster: the most a single thing a beacon can make is worth.
local function hardest_difficulty(): number
	local hardest = 0
	for _, option in SPAWNS do
		hardest = math.max(hardest, difficulty_of(option.def_name))
	end
	return hardest
end

-- The budget is what the scavengers may field, in difficulty, and it grows exponentially with progress:
-- `SCAVENGER_BUDGET_START` at the start, times e to this rate for every whole game. The rate is not chosen but
-- worked out, so that the budget reaches `SCAVENGER_ROSTER_COPIES` times the hardest thing in the roster at
-- `SCAVENGER_ROSTER_PROGRESS`: by then everything the game has can be afforded and fielded, and past it the
-- budget only buys more of it. There is nothing harder to unlock until there is a third tier. It stays above
-- the start so that a roster of one cheap thing has a rate.
local budget_rate = math.log(
	math.max(hardest_difficulty() * config.SCAVENGER_ROSTER_COPIES, config.SCAVENGER_BUDGET_START * 1.01)
		/ config.SCAVENGER_BUDGET_START
) / config.SCAVENGER_ROSTER_PROGRESS

local function budget(): number
	return config.SCAVENGER_BUDGET_START * math.exp(budget_rate * progress())
end

-- What the scavengers have out now, in difficulty: everything of theirs that is finished, apart from the beacons.
local function fielded_difficulty(): number
	local total = 0
	for _, other in state.all() do
		if
			other.alive
			and other.state == "active"
			and other.kind ~= "wreck"
			and is_scavenger(other)
			and is_beacon(other) == false
			and unit_defs.get(other.def_name).drone ~= true
		then
			total += difficulty_of(other.def_name)
		end
	end
	return total
end

-- `value` to `digits` significant figures, which is how a number that grows by orders of magnitude is shown
-- without changing every tick.
local function round_significant(value: number, digits: number): number
	if value < 1 then
		return 0
	end
	local step = 10 ^ (math.floor(math.log10(value)) - digits + 1)
	return math.round(value / step) * step
end

-- Whether something of `def` can drive in a straight line from `from` to `to`, stopping `stop_short` studs
-- before it: every step along the way has to be on the map, and on ground it may stand on, in water of the
-- right depth and not too steep.
local function has_direct_path(def: EntityDef, from: Vector3, to: Vector3, stop_short: number): boolean
	local offset = geometry.flatten(to - from)
	local length = offset.Magnitude - stop_short
	if length <= 0 then
		return true
	end
	local direction = offset.Unit
	for step = 1, math.ceil(length / PATH_SAMPLE_STEP) do
		local point = from + direction * math.min(length, step * PATH_SAMPLE_STEP)
		if heightmap.in_bounds(point.X, point.Z) == false then
			return false
		end
		local depth = heightmap.water_depth(point.X, point.Z)
		if
			unit_defs.tolerates_water(def, depth, depth) == false
			or passability.passable_at(def.slope_class, point.X, point.Z) == false
		then
			return false
		end
	end
	return true
end

-- Whether something that walks could get away from `center`: enough of the directions round it are open.
local function has_room_to_roam(center: Vector3, sea: boolean): boolean
	local probe = unit_defs.get(if sea then SEA_BEACON_PROBE_DEF else BEACON_PROBE_DEF)
	local open = 0
	for step = 0, 7 do
		local angle = step * (math.pi / 4)
		local to = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * BEACON_PROBE_LENGTH
		if has_direct_path(probe, center, to, 0) then
			open += 1
		end
	end
	return open >= BEACON_OPEN_DIRECTIONS
end

-- The first free place for `def_name` spiralling out from `around`, no nearer than `start`. Units face away
-- from the middle; a building stays square to the grid.
local function find_spot(def_name: string, around: Vector3, start: number): Spot?
	local def = unit_defs.get(def_name)
	for ring = 0, SPAWN_RINGS - 1 do
		local radius = start + ring * SPAWN_RING_STEP
		local count = math.max(6, math.floor(math.pi * 2 * radius / SPAWN_RING_STEP))
		local first_angle = rng:NextNumber(0, math.pi * 2)
		for step = 0, count - 1 do
			local angle = first_angle + step * (math.pi * 2 / count)
			local facing = if def.kind == "building" then 0 else math.atan2(math.cos(angle), math.sin(angle))
			local center = placement.resolve_center(
				def_name,
				around.X + math.cos(angle) * radius,
				around.Z + math.sin(angle) * radius,
				facing
			)
			if center ~= nil and placement.can_place(def_name, center, facing, nil) then
				return { position = center, facing = facing }
			end
		end
	end
	return nil
end

-- Whether a beacon could stand at `center` without being on top of a player or another beacon.
local function is_beacon_site_clear(center: Vector3): boolean
	for _, other in state.all() do
		if other.alive == false or other.kind == "wreck" then
			continue
		end
		local distance = geometry.distance_2d(center, other.position)
		if is_scavenger(other) then
			if is_beacon(other) and distance < config.SCAVENGER_BEACON_SPACING then
				return false
			end
		elseif distance < config.SCAVENGER_BEACON_PLAYER_CLEARANCE then
			return false
		end
	end
	return true
end

-- Puts a beacon down at a random empty place well away from the players, on dry level ground or floating on the
-- sea: where there is water at the spot it is the kind that floats, and where there is not it is the land kind.
-- The very first beacon of the game is never a sea one, so a player never faces an opening threat they have no
-- way to reach. Returns whether one went down: on a crowded map, or one with nowhere it will stand, it can fail
-- to find room.
local function spawn_beacon(allow_sea: boolean): boolean
	local extent_x = config.MAP_CELLS_X * config.CELL_STUDS / 2 - config.SCAVENGER_BEACON_EDGE_MARGIN
	local extent_z = config.MAP_CELLS_Z * config.CELL_STUDS / 2 - config.SCAVENGER_BEACON_EDGE_MARGIN
	for _ = 1, BEACON_ATTEMPTS do
		local x = rng:NextNumber(-extent_x, extent_x)
		local z = rng:NextNumber(-extent_z, extent_z)
		local sea = allow_sea and heightmap.water_depth(x, z) > 0
		local def_name = if sea then SEA_BEACON_DEF else BEACON_DEF
		local center = placement.resolve_center(def_name, x, z, 0)
		if
			center ~= nil
			and placement.can_place(def_name, center, 0, nil)
			and is_beacon_site_clear(center)
			and has_room_to_roam(center, sea)
		then
			local beacon = state.create_entity(def_name, config.SCAVENGER_TEAM, center, 0, "active")
			-- published at once, so the next beacon's site check and this one's first spawns can see it
			state.flush()
			local unit_interval = config.SCAVENGER_SPAWN_INTERVAL
			local defense_interval = config.SCAVENGER_DEFENSE_SPAWN_INTERVAL
			-- Sea beacons spawn scavengers less frequently
			if sea then
				unit_interval *= config.SCAVENGER_SEA_SPAWN_MULTIPLIER
				defense_interval *= config.SCAVENGER_SEA_SPAWN_MULTIPLIER
			end
			beacons[beacon.id] = {
				next_unit_at = clock + config.SCAVENGER_INITIAL_SPAWN_DELAY + unit_interval,
				next_defense_at = clock + config.SCAVENGER_INITIAL_SPAWN_DELAY + defense_interval,
				sea = sea,
			}
			return true
		end
	end
	return false
end

-- Puts a beacon down at (x, z) regardless of players or roaming room, for testing: it still snaps to
-- the nearest valid land or sea spot the way spawn_beacon does, but skips is_beacon_site_clear and
-- has_room_to_roam, and starts making things right away rather than waiting out the usual initial
-- delay. Returns whether one went down; it can still fail if there is nowhere for it to stand at all.
local function force_beacon(x: number, z: number): boolean
	local sea = heightmap.water_depth(x, z) > 0
	local def_name = if sea then SEA_BEACON_DEF else BEACON_DEF
	local center = placement.resolve_center(def_name, x, z, 0)
	if center == nil or placement.can_place(def_name, center, 0, nil) == false then
		return false
	end
	local beacon = state.create_entity(def_name, config.SCAVENGER_TEAM, center, 0, "active")
	state.flush()
	beacons[beacon.id] = {
		next_unit_at = clock,
		next_defense_at = clock,
		sea = sea,
	}
	return true
end

local function beacon_interval(): number
	return rng:NextNumber(config.SCAVENGER_BEACON_INTERVAL_MIN, config.SCAVENGER_BEACON_INTERVAL_MAX)
end

local function count_beacons(): number
	local count = 0
	for _ in beacons do
		count += 1
	end
	return count
end

-- Whether anyone but the scavengers has anything in the air, which is all a weapon that only hits aircraft is good for.
local function enemy_air_exists(): boolean
	for _, other in state.all() do
		if
			other.alive
			and other.kind == "unit"
			and is_scavenger(other) == false
			and unit_defs.is_air(unit_defs.get(other.def_name))
		then
			return true
		end
	end
	return false
end

-- What the scavengers already have out: every unit of theirs on the map, or the defences standing round
-- `beacon`.
local function existing(beacon: Entity, defense: boolean): { Entity }
	local found: { Entity } = {}
	for _, other in state.all() do
		if other.alive == false or other.state ~= "active" or is_scavenger(other) == false then
			continue
		end
		if defense then
			if
				other.kind == "building"
				and is_beacon(other) == false
				and geometry.distance_2d(other.position, beacon.position) <= DEFENSE_SCAN_RADIUS
			then
				table.insert(found, other)
			end
		elseif other.kind == "unit" and unit_defs.get(other.def_name).drone ~= true then
			table.insert(found, other)
		end
	end
	return found
end

-- The easiest of `present` to do without. A unit in the middle of an attack is never the one, so nothing
-- disappears in front of a player.
local function weakest_of(present: { Entity }): Entity?
	local weakest: Entity? = nil
	local weakest_difficulty = math.huge
	for _, other in present do
		local order = other.orders[1]
		if order ~= nil and order.kind == "attack" then
			continue
		end
		local difficulty = difficulty_of(other.def_name)
		if difficulty < weakest_difficulty then
			weakest = other
			weakest_difficulty = difficulty
		end
	end
	return weakest
end

-- Picks by weight among the units, or the defences, that fit in `headroom`: what is left of the budget, and that
-- a beacon on the sea, or on the land, makes.
local function choose_spawn(defense: boolean, headroom: number, sea: boolean, air_around: boolean): string?
	-- what is too easy to be worth making once there is something harder that a beacon here can make at all
	local fodder_below = budget() * FODDER_SHARE
	local roster_has_strong = false
	local options: { Spawn } = {}
	for _, option in SPAWNS do
		local is_defense = unit_defs.get(option.def_name).kind == "building"
		if is_defense ~= defense or (option.sea == true) ~= sea then
			continue
		end
		-- what only shoots at aircraft is made only while there are aircraft to shoot at
		if air_around == false and is_anti_air_only(unit_defs.get(option.def_name)) then
			continue
		end
		if difficulty_of(option.def_name) >= fodder_below then
			roster_has_strong = true
		end
		if difficulty_of(option.def_name) <= headroom then
			table.insert(options, option)
		end
	end

	-- with the harder things on offer the fodder is left out altogether, even if that leaves nothing that fits for
	-- now: a beacon then waits for room rather than filling it with the easy things
	local total = 0
	local chosen: { Spawn } = {}
	for _, option in options do
		if roster_has_strong == false or difficulty_of(option.def_name) >= fodder_below then
			table.insert(chosen, option)
			total += option.weight
		end
	end
	options = chosen
	if #options == 0 then
		return nil
	end

	local roll = rng:NextNumber(0, total)
	for _, option in options do
		roll -= option.weight
		if roll <= 0 then
			return option.def_name
		end
	end
	return options[#options].def_name
end

-- Makes one unit, or one defence, beside `beacon`. When there are already as many as are allowed it makes room
-- only by retiring something much easier than what it is about to make, without a wreck. Without that, a cap filled
-- early with the easiest things would leave everything unlocked later with no way in.
local function spawn_at(beacon: Entity, record: Beacon, defense: boolean)
	local def_name = choose_spawn(defense, budget() - fielded_difficulty(), record.sea, enemy_air_exists())
	if def_name == nil then
		return
	end

	local present = existing(beacon, defense)
	local limit = if defense then config.SCAVENGER_MAX_DEFENSES_PER_BEACON else config.SCAVENGER_MAX_UNITS
	if #present >= limit then
		local weakest = weakest_of(present)
		if weakest == nil or difficulty_of(weakest.def_name) * UPGRADE_FACTOR > difficulty_of(def_name) then
			return
		end
		state.mark_dead(weakest)
	end

	local start = if defense then DEFENSE_RING_START else UNIT_RING_START
	local spot = find_spot(def_name, beacon.position, start)
	if spot == nil then
		return
	end
	state.create_entity(def_name, config.SCAVENGER_TEAM, spot.position, spot.facing, "active")
	-- published at once, so the next thing this beacon makes sees this one as occupying its place
	state.flush()
end

local function run_beacons()
	for id, record in beacons do
		local beacon = state.get(id)
		if beacon == nil then
			-- destroyed, so it makes nothing more
			beacons[id] = nil
			continue
		end
		if clock >= record.next_unit_at then
			record.next_unit_at = clock + config.SCAVENGER_SPAWN_INTERVAL
			spawn_at(beacon, record, false)
		end
		-- a beacon that has all the defences it will take just skips this: it never costs it a unit
		if clock >= record.next_defense_at then
			record.next_defense_at = clock + config.SCAVENGER_DEFENSE_SPAWN_INTERVAL
			spawn_at(beacon, record, true)
		end
	end
end

-- Beacons wait for the game to get far enough along, and then come at random gaps, while fewer than the
-- limit stand.
local function run_beacon_schedule()
	if progress() < config.SCAVENGER_FIRST_BEACON_PROGRESS or clock < next_beacon_at then
		return
	end
	if count_beacons() >= config.SCAVENGER_MAX_BEACONS then
		next_beacon_at = clock + beacon_interval()
	elseif spawn_beacon(count_beacons() > 0) then
		next_beacon_at = clock + beacon_interval()
	else
		next_beacon_at = clock + BEACON_RETRY_DELAY
	end
end

-- The nearest thing of a player's that `unit` can shoot at and has noticed, and whether it has a straight run at
-- it. With none that it has a straight run at, it is the nearest of those it has not, for a route: they are worth
-- one only if a way round exists. `avoid` is one that is not to be considered, because there was no way to it.
local function find_target(unit: Entity, def: EntityDef, weapon: Weapon, avoid: EntityId?): (Entity?, boolean)
	local reach = reach_of(def)
	if reach == nil then
		return nil, false
	end

	local candidates: { Entity } = {}
	for _, other in state.all() do
		if
			combat.is_enemy(unit, other)
			and combat.can_target(weapon, other)
			and other.id ~= avoid
			and geometry.distance_2d(unit.position, other.position) <= config.SCAVENGER_DETECTION_RANGE
		then
			table.insert(candidates, other)
		end
	end
	table.sort(candidates, function(a: Entity, b: Entity): boolean
		return geometry.distance_2d(unit.position, a.position) < geometry.distance_2d(unit.position, b.position)
	end)

	local detour: Entity? = nil
	for index, other in candidates do
		if index > TARGET_PATH_CHECKS then
			break
		end
		if has_direct_path(def, unit.position, other.position, reach * RANGE_MARGIN) then
			return other, true
		end
		if detour == nil then
			detour = other
		end
	end
	return detour, false
end

-- The spot of its own that a hunter goes to round its target, at shooting range on the side it is coming from,
-- or nil if that is off the map. It comes from the unit's id, so it stays the same from one moment to the next
-- and different units fall in different places.
local function hunt_slot(unit: Entity, def: EntityDef, target: Entity): Vector3?
	local reach = reach_of(def)
	if reach == nil then
		return nil
	end
	local from_target = geometry.flatten(unit.position - target.position)
	local approach = if from_target.Magnitude > 1e-3 then math.atan2(from_target.Z, from_target.X) else 0
	local angle = approach + ((unit.id * SLOT_ID_STRIDE) % 1 - 0.5) * SLOT_SPREAD
	local x = target.position.X + math.cos(angle) * reach * RANGE_MARGIN
	local z = target.position.Z + math.sin(angle) * reach * RANGE_MARGIN
	if heightmap.in_bounds(x, z) == false then
		return nil
	end
	return heightmap.ground_position(x, z)
end

-- What a hunter does about `target`. Hidden behind the ground within reach where it cannot be shot, it walks on
-- toward it until it can be seen; a shell that is lobbed needs no sight. Otherwise it goes to a spot of its own
-- at shooting range on the side it is coming from, and attacks once it is there. Hunters that all made straight
-- for the target would stop in a clump at the front and leave the ones behind unable to get into range.
local function hunt_order(unit: Entity, def: EntityDef, weapon: Weapon, target: Entity): Order
	local attack: Order = { kind = "attack", target_id = target.id }
	local reach = reach_of(def)
	if reach == nil then
		return attack
	end
	-- a bomber attacks by flying over its target, which an attack order is what makes it do
	if def.air ~= nil and def.air.bombing_runs == true then
		return attack
	end
	-- a carrier with nothing of its own to shoot goes to its spot and stays, and its drones do the fighting
	if def.weapon == nil and def.turrets == nil and def.carrier ~= nil then
		return { kind = "move", position = hunt_slot(unit, def, target) or unit.position }
	end

	local lobbed = weapon.projectile ~= nil and weapon.projectile.arc ~= nil
	if
		lobbed == false
		and geometry.distance_2d(unit.position, target.position) <= reach
		and sight.verdict(unit, target, sight.muzzle_of(unit)) == "terrain"
	then
		return { kind = "move", position = target.position }
	end

	local slot = hunt_slot(unit, def, target)
	if slot == nil then
		return attack
	end
	if geometry.distance_2d(unit.position, slot) <= SLOT_ARRIVE_DISTANCE then
		return attack
	end
	-- no straight run to its spot: the plain attack order still gets it as close as it can
	if has_direct_path(def, unit.position, slot, 0) == false then
		return attack
	end
	return { kind = "move", position = slot }
end

local function is_same_order(current: Order?, wanted: Order): boolean
	if current == nil or current.kind ~= wanted.kind or current.target_id ~= wanted.target_id then
		return false
	end
	if wanted.position == nil then
		return true
	end
	return current.position ~= nil and geometry.distance_2d(current.position, wanted.position) < 2
end

-- Asks for a route from `unit` to `goal`, if this step has any left to give. nil means none was made, and the unit
-- goes on with what it had and asks again at its next thought.
local function plan_route(unit: Entity, def: EntityDef, goal: Vector3): Path?
	if paths_left <= 0 then
		return nil
	end
	paths_left -= 1
	return pathfinder.find_path(def, unit.position, goal, PATH_MAX_EXPANSIONS)
end

-- Whether something of `def` can stand at (x, z): the water is the right depth and the ground is not too steep.
local function is_standable(def: EntityDef, x: number, z: number): boolean
	if heightmap.in_bounds(x, z) == false then
		return false
	end
	local depth = heightmap.water_depth(x, z)
	return unit_defs.tolerates_water(def, depth, depth) and passability.passable_at(def.slope_class, x, z)
end

-- Goes after `target`, which it has no straight run at, by a route: to its own spot beside it and then an attack.
-- It counts the route as good if it gets all the way, or, when there is water or a cliff between, as far as a
-- place that is within reach of it, since it can shoot across. Otherwise it gives the target up for a while.
local function hunt_by_route(unit: Entity, brain: Brain, def: EntityDef, target: Entity)
	local anchor = brain.route_anchor
	if
		brain.route_target == target.id
		and anchor ~= nil
		and unit.orders[1] ~= nil
		and clock < brain.route_until
		and geometry.distance_2d(anchor, target.position) <= ROUTE_TARGET_DRIFT
	then
		return
	end
	if clock < brain.next_path_at then
		return
	end

	local path = plan_route(unit, def, hunt_slot(unit, def, target) or target.position)
	if path == nil then
		return
	end
	brain.next_path_at = clock + ROUTE_COOLDOWN

	local last = path.orders[#path.orders]
	local reach = reach_of(def) or 0
	local near_enough = path.complete
		or (last ~= nil and geometry.distance_2d(last.position or unit.position, target.position) <= reach)
	if last == nil or near_enough == false then
		brain.hunting = false
		brain.route_target = nil
		brain.avoid_target = target.id
		brain.avoid_until = clock + AVOID_TIME
		brain.next_path_at = clock + PATH_RETRY_DELAY
		unit.orders = {}
		return
	end

	local chain = table.clone(path.orders)
	table.insert(chain, { kind = "attack", target_id = target.id })
	orders.issue(unit, chain, false, false)
	brain.route_target = target.id
	brain.route_anchor = target.position
	brain.route_until = clock + ROUTE_HOLD
end

-- For a unit with nowhere it has a straight run to: a route to somewhere else on the map it could stand, if there
-- is one, so that a unit stranded behind a lake or a ridge is not stranded for good.
local function roam_by_route(unit: Entity, brain: Brain, def: EntityDef)
	if clock < brain.next_path_at then
		return
	end
	local extent_x = config.MAP_CELLS_X * config.CELL_STUDS / 2
	local extent_z = config.MAP_CELLS_Z * config.CELL_STUDS / 2
	for _ = 1, ROAM_ROUTE_TRIES do
		local x = rng:NextNumber(-extent_x, extent_x)
		local z = rng:NextNumber(-extent_z, extent_z)
		if is_standable(def, x, z) then
			local path = plan_route(unit, def, heightmap.ground_position(x, z))
			if path == nil then
				return
			end
			brain.next_path_at = clock + PATH_RETRY_DELAY
			if path.complete and #path.orders > 0 then
				orders.issue(unit, path.orders, false, false)
			end
			return
		end
	end
end

-- The nearest thing of a player's anywhere on the map that `weapon` can be turned on, if any. `avoid` is one that
-- is not to be considered, because there was no way to it.
local function nearest_enemy(unit: Entity, weapon: Weapon, avoid: EntityId?): Entity?
	local nearest: Entity? = nil
	local nearest_distance = math.huge
	for _, other in state.all() do
		if combat.is_enemy(unit, other) and combat.can_target(weapon, other) and other.id ~= avoid then
			local distance = geometry.distance_2d(unit.position, other.position)
			if distance < nearest_distance then
				nearest = other
				nearest_distance = distance
			end
		end
	end
	return nearest
end

-- Goes looking for the nearest thing of a player's, wherever it is, and returns whether it is on its way. There is
-- a straight run to a staging spot near it, or there is a route, or the unit gives that one up for a while. Once it
-- is close enough to notice it, hunting takes over and this is not asked.
local function seek(unit: Entity, brain: Brain, def: EntityDef, weapon: Weapon): boolean
	-- only some units go looking, and which is fixed by the unit's id
	if (unit.id * SLOT_ID_STRIDE) % 1 >= config.SCAVENGER_SEEKER_SHARE then
		return false
	end
	-- already on its way, by a route it was given not long ago
	if brain.seeking and unit.orders[1] ~= nil and clock < brain.route_until then
		return true
	end
	if clock < brain.next_path_at then
		return false
	end

	local avoid = if clock < brain.avoid_until then brain.avoid_target else nil
	local target = nearest_enemy(unit, weapon, avoid)
	if target == nil then
		return false
	end
	local away = geometry.flatten(unit.position - target.position)
	local distance = away.Magnitude
	local stage_distance = config.SCAVENGER_DETECTION_RANGE * SEEK_STAGE_SHARE
	if distance <= stage_distance or distance < 1e-3 then
		return false
	end
	local x = target.position.X + away.X / distance * stage_distance
	local z = target.position.Z + away.Z / distance * stage_distance
	if heightmap.in_bounds(x, z) == false then
		return false
	end
	local stage = heightmap.ground_position(x, z)

	-- a straight run is nearly free, and needs no route
	if has_direct_path(def, unit.position, stage, 0) then
		orders.issue(unit, { { kind = "move", position = stage } }, false, false)
		brain.seeking = true
		brain.route_target = nil
		brain.route_until = clock + ROUTE_HOLD
		brain.next_path_at = clock + ROUTE_COOLDOWN
		return true
	end

	local path = plan_route(unit, def, stage)
	if path == nil then
		return false
	end
	brain.next_path_at = clock + ROUTE_COOLDOWN
	local last = path.orders[#path.orders]
	local end_position = if last ~= nil then last.position else nil
	local got_somewhere = end_position ~= nil
		and distance - geometry.distance_2d(end_position, target.position) >= SEEK_MIN_PROGRESS
	if got_somewhere == false then
		brain.seeking = false
		brain.avoid_target = target.id
		brain.avoid_until = clock + AVOID_TIME
		brain.next_path_at = clock + PATH_RETRY_DELAY
		return false
	end
	orders.issue(unit, path.orders, false, false)
	brain.seeking = true
	brain.route_target = nil
	brain.route_until = clock + ROUTE_HOLD
	return true
end

-- Somewhere for `unit` to wander to: a random spot a fair way off that it has a straight run at.
local function pick_waypoint(unit: Entity, def: EntityDef): Vector3?
	for attempt = 1, ROAM_ATTEMPTS * 2 do
		-- the long wanders first, then shorter ones for a unit with little ground to go on
		local distance = if attempt <= ROAM_ATTEMPTS
			then rng:NextNumber(config.SCAVENGER_ROAM_MIN, config.SCAVENGER_ROAM_MAX)
			else rng:NextNumber(ROAM_SHORT_MIN, config.SCAVENGER_ROAM_MIN)
		local angle = rng:NextNumber(0, math.pi * 2)
		local x = unit.position.X + math.cos(angle) * distance
		local z = unit.position.Z + math.sin(angle) * distance
		if heightmap.in_bounds(x, z) then
			local point = heightmap.ground_position(x, z)
			if has_direct_path(def, unit.position, point, 0) then
				return point
			end
		end
	end
	return nil
end

-- Somewhere far off in the direction `outward`, give or take, for a unit that has just appeared and has to get
-- clear of the others.
local function pick_scatter_point(unit: Entity, def: EntityDef, outward: Vector3): Vector3?
	for _ = 1, ROAM_ATTEMPTS do
		local turn = rng:NextNumber(-SCATTER_FAN, SCATTER_FAN)
		local cosine = math.cos(turn)
		local sine = math.sin(turn)
		local distance = rng:NextNumber(config.SCAVENGER_ROAM_MIN, config.SCAVENGER_ROAM_MAX)
		local x = unit.position.X + (outward.X * cosine - outward.Z * sine) * distance
		local z = unit.position.Z + (outward.X * sine + outward.Z * cosine) * distance
		if heightmap.in_bounds(x, z) then
			local point = heightmap.ground_position(x, z)
			if has_direct_path(def, unit.position, point, 0) then
				return point
			end
		end
	end
	return nil
end

local function brain_for(unit: Entity): Brain
	local brain = brains[unit.id]
	if brain == nil then
		brain = {
			-- staggered, so a whole wave does not do all its thinking on the same tick
			next_think = clock + rng:NextNumber(0, THINK_INTERVAL),
			last_position = unit.position,
			stuck_for = 0,
			ignore_until = 0,
			scattered = false,
			hunting = false,
			seeking = false,
			next_path_at = 0,
			route_target = nil,
			route_anchor = nil,
			route_until = 0,
			avoid_target = nil,
			avoid_until = 0,
		}
		brains[unit.id] = brain
	end
	return brain
end

-- One unit making up its mind: hunt what it can reach, otherwise keep wandering.
local function think(unit: Entity, brain: Brain)
	local def = unit_defs.get(unit.def_name)
	brain.next_think = clock + THINK_INTERVAL

	-- `movement` still holds last tick's goals here, so this is whether it was trying to go somewhere
	local moved = geometry.distance_2d(unit.position, brain.last_position)
	brain.last_position = unit.position
	if movement.has_goal(unit.id) and moved < STUCK_DISTANCE then
		brain.stuck_for += THINK_INTERVAL
	else
		brain.stuck_for = 0
	end
	if brain.stuck_for >= STUCK_LIMIT then
		-- a lake or the edge of the map in the way: give up on it and wander somewhere else for a while
		brain.stuck_for = 0
		brain.ignore_until = clock + STUCK_IGNORE_TIME
		brain.hunting = false
		brain.seeking = false
		brain.route_target = nil
		unit.orders = {}
	end

	-- The first thing a new unit does is head away from the others, so a wave does not stand about in a clump
	-- at its beacon, or all set off after the same thing from the same place.
	if brain.scattered == false then
		brain.scattered = true
		local outward = Vector3.new(math.sin(unit.facing), 0, math.cos(unit.facing))
		local point = pick_scatter_point(unit, def, outward)
		if point ~= nil then
			brain.ignore_until = clock + SCATTER_TIME
			brain.hunting = false
			orders.issue(unit, { { kind = "move", position = point } }, false, false)
			return
		end
	end

	local weapon = main_weapon(def)
	if weapon ~= nil and clock >= brain.ignore_until then
		local avoid = if clock < brain.avoid_until then brain.avoid_target else nil
		local target, direct = find_target(unit, def, weapon, avoid)
		if target ~= nil then
			brain.hunting = true
			brain.seeking = false
			if direct == false then
				hunt_by_route(unit, brain, def, target)
				return
			end
			brain.route_target = nil
			local wanted = hunt_order(unit, def, weapon, target)
			if is_same_order(unit.orders[1], wanted) == false then
				orders.issue(unit, { wanted }, false, false)
			end
			return
		end
		-- whatever it was chasing is gone, or out of reach, so the chase is over
		if brain.hunting then
			brain.hunting = false
			brain.route_target = nil
			unit.orders = {}
		end
		-- nothing near enough to notice: go looking for something further off
		if seek(unit, brain, def, weapon) then
			return
		end
	end

	if unit.orders[1] == nil then
		local point = pick_waypoint(unit, def)
		if point ~= nil then
			orders.issue(unit, { { kind = "move", position = point } }, false, false)
		else
			roam_by_route(unit, brain, def)
		end
	end
end

local function run_brains()
	for _, unit in state.all() do
		if is_scavenger(unit) == false or unit.alive == false or movement.is_mobile(unit) == false then
			continue
		end
		-- a drone is its carrier's to send out, and to call back
		if unit_defs.get(unit.def_name).drone == true then
			continue
		end
		local brain = brain_for(unit)
		if clock >= brain.next_think then
			think(unit, brain)
		end
	end
end

-- The wrecks of units come back as scavengers. While the gamemode is on every one gains resurrection progress, the
-- progress the purple bar over it shows and a Graverobber works on, at the rate that fills it in
-- `SCAVENGER_REVIVE_SECONDS`, and when it is full the wreck is gone and the unit stands in its place on the
-- scavengers' team, with the health a raised unit has. It costs them nothing. Only units come back, as with a
-- Graverobber, and never a commander. With as many scavenger units out as are allowed it waits, full, for room; and
-- whatever takes the wreck apart first, by reclaiming it, wins.
local function run_revival(delta: number)
	local unit_count = 0
	local wrecks: { Entity } = {}
	for _, other in state.all() do
		if other.alive == false then
			continue
		end
		if other.kind == "wreck" then
			table.insert(wrecks, other)
		elseif
			other.kind == "unit"
			and other.state == "active"
			and is_scavenger(other)
			and unit_defs.get(other.def_name).drone ~= true
		then
			unit_count += 1
		end
	end

	for _, wreck_entity in wrecks do
		local wreck = wreck_entity.wreck
		if wreck == nil then
			continue
		end
		local source = unit_defs.get(wreck.source_def_name)
		if source.kind ~= "unit" or source.nametag == true or source.buildpower_cost <= 0 then
			continue
		end
		local cost = source.buildpower_cost
		wreck.resurrect_progress =
			math.min(cost, wreck.resurrect_progress + cost * delta / config.SCAVENGER_REVIVE_SECONDS)
		if wreck.resurrect_progress >= cost and unit_count < config.SCAVENGER_MAX_UNITS then
			local raised = state.create_entity(
				wreck.source_def_name,
				config.SCAVENGER_TEAM,
				wreck_entity.position,
				wreck_entity.facing,
				"active"
			)
			raised.health = raised.max_health * config.RESURRECT_HEALTH_FRACTION
			state.mark_dead(wreck_entity)
			unit_count += 1
		end
	end
end

local function init()
	if state.get_team(config.SCAVENGER_TEAM) == nil then
		local team = state.create_team(config.SCAVENGER_TEAM)
		team.name = "Scavengers"
	end
end

-- Called once per step, after income and before orders, so what a unit decides here is what it does this
-- step.
local function tick(delta: number)
	clock += delta
	paths_left = PATHS_PER_TICK

	-- Scavengers have no economy: their weapons never want for energy, however many are firing.
	local team = state.get_team(config.SCAVENGER_TEAM)
	if team ~= nil then
		team.energy = team.energy_capacity
	end

	local shown: number? = if enabled then round_significant(budget(), SHOWN_DIGITS) else nil
	if Workspace:GetAttribute(DIFFICULTY_ATTRIBUTE) ~= shown then
		Workspace:SetAttribute(DIFFICULTY_ATTRIBUTE, shown)
	end

	if enabled then
		run_beacon_schedule()
		run_beacons()
		run_revival(delta)
	end
	-- a beacon that stops making things does not stop what it already made
	run_brains()
end

-- Sets how far the game has got, from 0 to 1, from now on: it carries on rising from there. The budget follows it,
-- and it is the only thing that does, so it is what sets the difficulty. Returns the progress it was set to.
local function set_progress(fraction: number): number
	local wanted = math.clamp(fraction, 0, 1)
	progress_offset = wanted * config.SCAVENGER_GAME_LENGTH - clock
	return wanted
end

-- Sets the progress to what makes the budget `score` (the difficulty on the scavengers' readout) and returns the
-- progress and the budget that came of it. A score outside what the budget goes through, from its start to where it
-- stops growing, is taken to the nearest end.
local function set_difficulty(score: number): (number, number)
	local wanted = if score > 0 and budget_rate > 0
		then math.log(score / config.SCAVENGER_BUDGET_START) / budget_rate
		else 0
	local set = set_progress(wanted)
	return set, budget()
end

-- Turning it off stops new beacons and stops standing ones making anything; what is already out there
-- carries on. The game's progress keeps rising meanwhile, so turning it on again picks up where it has got to.
local function set_enabled(value: boolean)
	enabled = value
end

local function is_enabled(): boolean
	return enabled
end

-- Puts a beacon down now, whatever the schedule says. Returns whether there was room.
local function summon_beacon(): boolean
	return spawn_beacon(count_beacons() > 0)
end

local function forget(entity_id: EntityId)
	brains[entity_id] = nil
	beacons[entity_id] = nil
end

return table.freeze({
	init = init,
	tick = tick,
	set_enabled = set_enabled,
	is_enabled = is_enabled,
	summon_beacon = summon_beacon,
	force_beacon = force_beacon,
	progress = progress,
	set_progress = set_progress,
	set_difficulty = set_difficulty,
	budget = budget,
	fielded_difficulty = fielded_difficulty,
	forget = forget,
})
