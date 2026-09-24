-- The scavengers gamemode. As the game begins a beacon stands in a start nobody took, and every few minutes
-- another goes up near one already standing, so that they spread out over the map. Once the game is far enough
-- along, every beacon keeps producing hostile units and defences around itself, so the more beacons stand the more
-- come. The units scatter across the map and hunt: anything of a player's that one notices, and has a way to, it
-- attacks.
--
-- The scavengers are a team of their own (`config.SCAVENGER_TEAM`), so everything `combat` already knows
-- about enemies applies to them without a special case: defences shoot whatever comes into range, and a
-- player's units shoot them back. Only the beacon's schedule and what the units decide to do live here.
--
-- A unit on the ground only ever goes somewhere by a "straight run", a line across ground it can stand on all the
-- way (`pathfinder.has_straight_path`), which is nearly free, or when there is none by a route from `pathfinder`.
-- That holds for going after something it has noticed as well: it goes to where it will shoot from, and never just
-- straight at the thing, which up on a cliff would run it into the cliff. A route costs anything from a millisecond
-- to a good deal more, so there is a limit on how many are asked for and how far each may search, and a unit that
-- is refused waits before it tries again.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local passability = require(ReplicatedStorage.Shared.passability)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local starts = require(ReplicatedStorage.Shared.starts)
local game_phase = require(ReplicatedStorage.Shared.game_phase)

local state = require(script.Parent.state)
local orders = require(script.Parent.orders)
local combat = require(script.Parent.combat)
local movement = require(script.Parent.movement)
local placement = require(script.Parent.placement)

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
	-- made by a beacon that floats on the sea, and by no other; everything else is made by a land one,
	-- unless it is amphibious
	sea: boolean?,
	-- an aircraft, a hovercraft or an amphibious walker (`can_cross`): it gets away from wherever it is made, so a
	-- beacon of either kind can make it
	amphibious: boolean?,
}

-- Units and defences are made on separate clocks, so that a beacon ringed with all the defences it will take
-- goes on making units.
type Beacon = {
	next_unit_at: number,
	next_defense_at: number,
	-- whether it floats on the sea, and makes ships, or stands on the land
	sea: boolean,
	-- whether it makes things before the game has got to `SCAVENGER_SPAWN_PROGRESS`, as a forced one does
	eager: boolean,
	-- the beacon itself, kept so that once it is gone `forget` can still tell whether it was destroyed or only
	-- cleared away with the map
	entity: Entity,
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
	-- The last time it got anything done (`SCAVENGER_FUTILE_SECONDS`), when it next looks at how near it is to the
	-- nearest thing of a player's, and the nearest it has been to that thing.
	useful_at: number,
	next_futile_check: number,
	closest: number,
	closest_target: EntityId?,
}

type Spot = {
	position: Vector3,
	facing: number,
}

-- What the client is told: the scavengers' budget, the hardest thing they may make now, in this
-- attribute of Workspace, and nothing at all while the gamemode is off, which is how the client knows whether to
-- show it. It is rounded to two significant figures, so it changes every twenty seconds or so at most rather
-- than every tick.
local SHOWN_DIGITS = 2
local DIFFICULTY_ATTRIBUTE = "scavenger_difficulty"

local BEACON_DEF = "scavenger_beacon"
local SEA_BEACON_DEF = "scavenger_sea_beacon"
local BOSS_DEF = "scavenger_boss"
-- What the players are told when it falls.
local BOSS_DEFEATED = "The Scavenger Overlord has fallen"
local BEACON_ATTEMPTS = 40
local BEACON_RETRY_DELAY = 10
-- The first beacon is looked for in rings this far apart round its start box's start, as far as the box goes.
local START_SEARCH_STEP = 8

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

-- Fodder: what is worth less than this share of the hardest thing a beacon could make now is not made. So the easiest
-- things go first as the budget grows, and by the end of the game only the hardest few are made.
local FODDER_SHARE = 0.12

-- When a beacon has all the defences it will take, something new retires the weakest only if it is at least this
-- many times as hard, so what stands there stays a spread of easy and hard rather than all of the newest.
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

-- Tries at a long wander, and then as many at a short one, for a unit that is on ground with little room.
local ROAM_ATTEMPTS = 8
local ROAM_SHORT_MIN = 10
-- A new unit heads off away from its beacon by up to this far either side of straight out, and leaves the
-- hunting alone for this long, so that a wave does not stay bunched on the spot it appeared.
local SCATTER_FAN = math.pi / 3
local SCATTER_TIME = 5
-- A hunter walks to a spot of its own on a ring round its target, spread over this much of the ring on the
-- side it comes from. The spot comes from its id, so it stays the same from one moment to the next, and different
-- ids fall in different places.
local SLOT_SPREAD = math.pi
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
-- How often a unit looks at whether it is getting anywhere (`SCAVENGER_FUTILE_SECONDS`), and how often what the
-- units that got nowhere were worth is spent on something that can get across (`run_reroll`).
local FUTILE_CHECK_INTERVAL = 5
local REROLL_INTERVAL = 1
-- Water this deep is deeper than any sea on the maps, and still within what an amphibious walker goes through (BAR's
-- 5000 elmos, about 454 studs): what a rerolled unit has to manage.
local CROSSING_DEPTH = 400
-- Close in to a little inside the nominal range, the same margin `orders` uses when it closes on a target, so
-- that "can it get within range" is asked of the spot it would actually stop at.
local RANGE_MARGIN = 0.85

local rng = Random.new()
local clock = 0
-- Added to the clock for the game's progress alone, so that progress can be set without moving the clock the
-- schedules run on.
local progress_offset = 0
-- How many seconds the game takes to reach full progress; a match against harder scavengers is shorter (see
-- `set_pace`).
local game_length = config.SCAVENGER_GAME_LENGTH
local enabled = config.SCAVENGERS_ENABLED
-- Whether the game has begun, as far as the scavengers are concerned: the first step anything of a player's stands
-- (see `open`).
local opened = false
-- When the next beacon goes up; nil until the beacons start making things, which is when the gaps start.
local next_beacon_at: number? = nil
local beacons: { [EntityId]: Beacon } = {}
local brains: { [EntityId]: Brain } = {}
-- How many more routes this step may ask for.
local paths_left = 0
-- When the scavengers' manual-fire weapons next look for something to fire at (`aim_manual_weapons`).
local next_aim_at = 0
-- What everything they field has in health, as a multiple of its def's; a match sets it from its difficulty.
local health_multiplier = 1
-- What the units that got nothing done were worth, in difficulty, still to be spent on ones that can get across,
-- and when it is next spent.
local reroll_credit = 0
local next_reroll_at = 0
-- Their boss, once it has come; it comes once a game.
local boss: Entity? = nil

local function is_scavenger(entity: Entity): boolean
	return entity.team == config.SCAVENGER_TEAM
end

local function is_beacon(entity: Entity): boolean
	return entity.def_name == BEACON_DEF or entity.def_name == SEA_BEACON_DEF
end

-- The weapon a unit's willingness to hunt is judged by: its first.
local function main_weapon(def: EntityDef): Weapon?
	if def.weapons ~= nil and #def.weapons > 0 then
		return def.weapons[1]
	end
	-- a carrier has nothing of its own, but its drones do
	if def.carrier ~= nil then
		return main_weapon(unit_defs.get(def.carrier.drone))
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

-- How far the game has got, from 0 to 1, rising steadily over `game_length` seconds. Nothing
-- the scavengers do is decided by anything else: beacons wait for it, and it is what their budget grows with.
local function progress(): number
	return math.clamp((clock + progress_offset) / game_length, 0, 1)
end

-- Sets how far the game has got, from 0 to 1, from now on: it carries on rising from there. The budget follows it,
-- and it is the only thing that does, so it is what sets the difficulty. Returns the progress it was set to.
local function set_progress(fraction: number): number
	local wanted = math.clamp(fraction, 0, 1)
	progress_offset = wanted * game_length - clock
	return wanted
end

-- How hard something is to face, for now just what it cost: its metal and its energy over 60. It is only a
-- stand-in for a better judgement, so it lives in this one function.
local function difficulty_of(def_name: string): number
	local def = unit_defs.get(def_name)
	return (def.metal_cost + def.energy_cost) / 60
end

-- Whether every weapon it has can only be turned on aircraft.
local function is_anti_air_only(def: EntityDef): boolean
	if def.weapons == nil or #def.weapons == 0 then
		return false
	end
	for _, weapon in def.weapons do
		if weapon.target_layer ~= "air" then
			return false
		end
	end
	return true
end

-- Whether something of `def` can get anywhere there is to get: it flies, or it can go on land and on water of any depth,
-- as a hovercraft or an amphibious walker can.
local function can_cross(def: EntityDef): boolean
	return def.air ~= nil or unit_defs.tolerates_water(def, 0, CROSSING_DEPTH)
end

-- Everything a player can build that fights, which is everything the scavengers can field: what is listed among
-- what some builder or factory makes, has a weapon or drones to fight with, and is not itself a drone. A beacon on
-- the sea makes what floats, and any other makes the rest; what can cross either (`can_cross`) comes from both. The list is sorted so that it is the same every time.
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
				amphibious = can_cross(def),
			})
		end
	end
	table.sort(roster, function(a: Spawn, b: Spawn): boolean
		return a.def_name < b.def_name
	end)
	return roster
end

local SPAWNS: { Spawn } = build_roster()

-- The budget is the hardest single thing a beacon may make now, in difficulty. It is not a limit on how much is
-- out: there is none, and how many come is up to how many beacons stand. It runs from `SCAVENGER_BUDGET_START` to
-- `SCAVENGER_BUDGET_END` over the game, a little slower than exponentially (see config): the log of how far it has
-- grown is `progress ^ SCAVENGER_BUDGET_SHAPE` of the way, which with a shape under 1 is ahead early and eases off.
local BUDGET_GROWTH = math.log(config.SCAVENGER_BUDGET_END / config.SCAVENGER_BUDGET_START)

local function budget(): number
	return config.SCAVENGER_BUDGET_START * math.exp(BUDGET_GROWTH * progress() ^ config.SCAVENGER_BUDGET_SHAPE)
end

-- How many units the scavengers have out, drones apart.
local function count_units(): number
	local count = 0
	for _, other in state.all() do
		if
			other.alive
			and other.kind == "unit"
			and other.state == "active"
			and is_scavenger(other)
			and unit_defs.of(other).drone ~= true
		then
			count += 1
		end
	end
	return count
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

-- Whether something that walks could get away from `center`: enough of the directions round it are open.
local function has_room_to_roam(center: Vector3, sea: boolean): boolean
	local probe = unit_defs.get(if sea then SEA_BEACON_PROBE_DEF else BEACON_PROBE_DEF)
	local open = 0
	for step = 0, 7 do
		local angle = step * (math.pi / 4)
		local to = center + Vector3.new(math.cos(angle), 0, math.sin(angle)) * BEACON_PROBE_LENGTH
		if pathfinder.has_straight_path(probe, center, to) then
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
		-- what lies about belonging to nobody is no player's
		if other.alive == false or other.kind == "wreck" or other.kind == "reclaimable" then
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

-- What something the scavengers field has in health: its def's times the difficulty's multiplier. It keeps the share of
-- its health it had.
local function toughen(entity: Entity)
	local fraction = entity.health / entity.max_health
	entity.max_health = unit_defs.of(entity).health * health_multiplier
	entity.health = entity.max_health * fraction
end

-- A beacon's health, which grows with the game's progress (`SCAVENGER_BEACON_HEALTH_GROWTH`), keeping the share of it
-- the beacon has.
local function grow_beacon(beacon: Entity)
	local wanted = unit_defs.of(beacon).health * (1 + config.SCAVENGER_BEACON_HEALTH_GROWTH * progress())
	if math.abs(wanted - beacon.max_health) < 1 then
		return
	end
	local fraction = beacon.health / beacon.max_health
	beacon.max_health = wanted
	beacon.health = wanted * fraction
end

-- Stands a beacon at `center`, a place already found for it, and sets it making things: `delay` seconds from now,
-- once the game is far enough along, or at once if it is `eager`.
local function place_beacon(center: Vector3, sea: boolean, delay: number, eager: boolean): Entity
	local beacon =
		state.create_entity(if sea then SEA_BEACON_DEF else BEACON_DEF, config.SCAVENGER_TEAM, center, 0, "active")
	-- published at once, so the next beacon's site check and this one's first spawns can see it
	state.flush()
	beacons[beacon.id] = {
		next_unit_at = clock + delay,
		next_defense_at = clock + delay,
		sea = sea,
		eager = eager,
		entity = beacon,
	}
	grow_beacon(beacon)
	return beacon
end

-- Where a beacon would stand near (x, z), and whether it is a sea one, if it can stand there at all: on dry level
-- ground, or floating on the sea where there is water at the spot, well away from the players and other beacons,
-- and with room round it for what it makes to get away.
local function beacon_site(x: number, z: number, allow_sea: boolean): (Vector3?, boolean)
	local half_x, half_z = heightmap.half_extents()
	local margin = config.SCAVENGER_BEACON_EDGE_MARGIN
	if math.abs(x) > half_x - margin or math.abs(z) > half_z - margin then
		return nil, false
	end
	local sea = allow_sea and heightmap.water_depth(x, z) > 0
	local def_name = if sea then SEA_BEACON_DEF else BEACON_DEF
	local center = placement.resolve_center(def_name, x, z, 0)
	if
		center ~= nil
		and placement.can_place(def_name, center, 0, nil)
		and is_beacon_site_clear(center)
		and has_room_to_roam(center, sea)
	then
		return center, sea
	end
	return nil, false
end

-- The beacons that stand, as entities.
local function standing_beacons(): { Entity }
	local found: { Entity } = {}
	for id in beacons do
		local beacon = state.get(id)
		if beacon ~= nil and beacon.alive then
			table.insert(found, beacon)
		end
	end
	return found
end

-- Puts a beacon down near one already standing, between `SCAVENGER_BEACON_SPACING` and `SCAVENGER_BEACON_SPREAD`
-- from it, so that they spread out from where they began; with none standing, or no room round any, anywhere on the
-- map. Units and defences come `SCAVENGER_INITIAL_SPAWN_DELAY` after it goes up, and a sea one makes them less
-- often. Returns whether one went down: on a crowded map, or one with nowhere it will stand, it can fail to find
-- room.
local function spawn_beacon(allow_sea: boolean): boolean
	local from = standing_beacons()
	local half_x, half_z = heightmap.half_extents()
	for attempt = 1, BEACON_ATTEMPTS * 2 do
		local x, z
		if attempt <= BEACON_ATTEMPTS and #from > 0 then
			local origin = from[rng:NextInteger(1, #from)].position
			local angle = rng:NextNumber(0, math.pi * 2)
			local distance = rng:NextNumber(config.SCAVENGER_BEACON_SPACING, config.SCAVENGER_BEACON_SPREAD)
			x = origin.X + math.cos(angle) * distance
			z = origin.Z + math.sin(angle) * distance
		elseif attempt > BEACON_ATTEMPTS then
			x = rng:NextNumber(-half_x, half_x)
			z = rng:NextNumber(-half_z, half_z)
		else
			continue
		end
		local center, sea = beacon_site(x, z, allow_sea)
		if center ~= nil then
			local multiplier = if sea then config.SCAVENGER_SEA_SPAWN_MULTIPLIER else 1
			place_beacon(
				center,
				sea,
				config.SCAVENGER_INITIAL_SPAWN_DELAY + config.SCAVENGER_SPAWN_INTERVAL * multiplier,
				false
			)
			return true
		end
	end
	return false
end

-- The start box no player has been given that is furthest from everything of the players', by index, if there is one.
local function free_box(): number?
	local taken: { [number]: boolean } = {}
	for _, player in Players:GetPlayers() do
		local index = game_phase.box_of(player)
		if index ~= nil then
			taken[index] = true
		end
	end
	local best: number? = nil
	local best_distance = -1
	for index = 1, starts.box_count() do
		if taken[index] then
			continue
		end
		local box = starts.box(index)
		local middle = (box.min + box.max) / 2
		local nearest = math.huge
		for _, other in state.all() do
			if
				other.alive
				and is_scavenger(other) == false
				and other.kind ~= "wreck"
				and other.kind ~= "reclaimable"
			then
				nearest = math.min(nearest, geometry.distance_2d(Vector3.new(middle.X, 0, middle.Y), other.position))
			end
		end
		if nearest > best_distance then
			best = index
			best_distance = nearest
		end
	end
	return best
end

-- The game has begun: the scavengers take a start box nobody else was given, and their first beacon stands in it,
-- making nothing until the game has got to `SCAVENGER_SPAWN_PROGRESS`. It goes up as near the box's start as it
-- will stand, on the land, so a player never faces an opening threat they have no way to reach. With every box
-- taken, it goes wherever there is room instead.
local function open()
	local index = free_box()
	if index ~= nil then
		local box = starts.box(index)
		local spot = starts.default_spot(index)
		local reach = (box.max - box.min).Magnitude
		for radius = 0, reach, START_SEARCH_STEP do
			local around = math.max(1, math.ceil(math.pi * 2 * radius / START_SEARCH_STEP))
			local first_angle = rng:NextNumber(0, math.pi * 2)
			for step = 0, around - 1 do
				local angle = first_angle + step * (math.pi * 2 / around)
				local x = spot.X + math.cos(angle) * radius
				local z = spot.Y + math.sin(angle) * radius
				if starts.in_box(index, x, z) == false then
					continue
				end
				local center = beacon_site(x, z, false)
				if center ~= nil then
					place_beacon(center, false, 0, false)
					return
				end
			end
		end
	end
	if spawn_beacon(false) == false then
		warn "the scavengers found nowhere to put their first beacon; the schedule will try again"
	end
end

-- Puts a beacon down at (x, z) regardless of players or roaming room, for testing: it still snaps to
-- the nearest valid land or sea spot the way spawn_beacon does, but skips is_beacon_site_clear and
-- has_room_to_roam, and starts making things right away, whatever the game's progress, rather than
-- waiting. Returns whether one went down; it can still fail if there is nowhere for it to stand at all.
local function force_beacon(x: number, z: number): EntityId?
	local sea = heightmap.water_depth(x, z) > 0
	local def_name = if sea then SEA_BEACON_DEF else BEACON_DEF
	local center = placement.resolve_center(def_name, x, z, 0)
	if center == nil or placement.can_place(def_name, center, 0, nil) == false then
		return nil
	end
	return place_beacon(center, sea, 0, true).id
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
			and unit_defs.is_air(unit_defs.of(other))
		then
			return true
		end
	end
	return false
end

-- The defences the scavengers have standing round `beacon`.
local function defenses_around(beacon: Entity): { Entity }
	local found: { Entity } = {}
	for _, other in state.all() do
		if
			other.alive
			and other.state == "active"
			and is_scavenger(other)
			and other.kind == "building"
			and is_beacon(other) == false
			and geometry.distance_2d(other.position, beacon.position) <= DEFENSE_SCAN_RADIUS
		then
			table.insert(found, other)
		end
	end
	return found
end

-- The easiest of `present` to do without. One in the middle of an attack is never the one, so nothing
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

-- The units, or the defences, that are no harder than `headroom`, the budget, and that a beacon on the sea, or on
-- the land, makes, less the fodder; and what their weights come to.
local function spawn_options(defense: boolean, headroom: number, sea: boolean, air_around: boolean): ({ Spawn }, number)
	local options: { Spawn } = {}
	-- the hardest of them, which is what the fodder is measured against
	local hardest = 0
	for _, option in SPAWNS do
		local is_defense = unit_defs.of(option).kind == "building"
		if is_defense ~= defense or (option.amphibious ~= true and (option.sea == true) ~= sea) then
			continue
		end
		-- what only shoots at aircraft is made only while there are aircraft to shoot at
		if air_around == false and is_anti_air_only(unit_defs.of(option)) then
			continue
		end
		if difficulty_of(option.def_name) <= headroom then
			table.insert(options, option)
			hardest = math.max(hardest, difficulty_of(option.def_name))
		end
	end

	-- what is too easy beside the hardest of it is left out
	local fodder_below = hardest * FODDER_SHARE
	local total = 0
	local chosen: { Spawn } = {}
	for _, option in options do
		if difficulty_of(option.def_name) >= fodder_below then
			table.insert(chosen, option)
			total += option.weight
		end
	end
	return chosen, total
end

-- Picks by weight among `spawn_options`.
local function choose_spawn(defense: boolean, headroom: number, sea: boolean, air_around: boolean): string?
	local options, total = spawn_options(defense, headroom, sea, air_around)
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

-- Their boss comes, near `near`: once a game, when the last beacon falls or the game's progress runs out. It has the
-- difficulty's health like everything else of theirs, and hunts as their units do. With it out no more beacons come.
local function summon_boss(near: Vector3)
	if boss ~= nil then
		return
	end
	local spot = find_spot(BOSS_DEF, near, UNIT_RING_START)
	local at = if spot ~= nil then spot.position else heightmap.ground_position(near.X, near.Z)
	local facing = if spot ~= nil then spot.facing else 0
	local summoned = state.create_entity(BOSS_DEF, config.SCAVENGER_TEAM, at, facing, "active")
	toughen(summoned)
	state.flush()
	boss = summoned
end

-- Their boss is dead: every team but theirs has won.
local function defeat_boss()
	local winners = {}
	for id in state.all_teams() do
		if id ~= config.SCAVENGER_TEAM then
			table.insert(winners, id)
		end
	end
	table.sort(winners)
	game_phase.set_ended(winners, BOSS_DEFEATED)
end

-- The beacon `id` is gone. If it was destroyed, and not only cleared away with the map, that moves the game on a
-- little, which is small beside the units it will not make; and the last one standing brings their boss, at once,
-- where it stood. Whichever of `run_beacons` and `forget` notices first, the beacon counts once.
local function lose_beacon(id: EntityId, record: Beacon)
	beacons[id] = nil
	if record.entity.health > 0 or enabled == false then
		return
	end
	set_progress(progress() + config.SCAVENGER_BEACON_KILL_PROGRESS)
	if count_beacons() == 0 then
		summon_boss(record.entity.position)
	end
end

-- Makes one unit, or one defence, beside `beacon`. Units have no limit but the server's ceiling. When a beacon
-- already has all the defences it will take it makes room only by retiring one much easier than what it is about to
-- make, without a wreck. Without that, a ring filled early with the easiest things would leave everything unlocked
-- later with no way in.
local function spawn_at(beacon: Entity, record: Beacon, defense: boolean)
	if defense == false and count_units() >= config.SCAVENGER_UNIT_CEILING then
		return
	end
	local def_name = choose_spawn(defense, budget(), record.sea, enemy_air_exists())
	if def_name == nil then
		return
	end

	if defense then
		local present = defenses_around(beacon)
		if #present >= config.SCAVENGER_MAX_DEFENSES_PER_BEACON then
			local weakest = weakest_of(present)
			if weakest == nil or difficulty_of(weakest.def_name) * UPGRADE_FACTOR > difficulty_of(def_name) then
				return
			end
			state.mark_dead(weakest)
		end
	end

	local start = if defense then DEFENSE_RING_START else UNIT_RING_START
	local spot = find_spot(def_name, beacon.position, start)
	if spot == nil then
		return
	end
	toughen(state.create_entity(def_name, config.SCAVENGER_TEAM, spot.position, spot.facing, "active"))
	-- published at once, so the next thing this beacon makes sees this one as occupying its place
	state.flush()
end

local function run_beacons()
	for id, record in beacons do
		local beacon = state.get(id)
		if beacon == nil then
			-- destroyed, so it makes nothing more
			lose_beacon(id, record)
			continue
		end
		grow_beacon(beacon)
		-- nothing is made before the game has got far enough along, and a beacon that has been waiting for it
		-- starts the moment it does
		if record.eager == false and progress() < config.SCAVENGER_SPAWN_PROGRESS then
			continue
		end
		local multiplier = if record.sea then config.SCAVENGER_SEA_SPAWN_MULTIPLIER else 1
		if clock >= record.next_unit_at then
			record.next_unit_at = clock + config.SCAVENGER_SPAWN_INTERVAL * multiplier
			spawn_at(beacon, record, false)
		end
		-- a beacon that has all the defences it will take just skips this: it never costs it a unit
		if clock >= record.next_defense_at then
			record.next_defense_at = clock + config.SCAVENGER_DEFENSE_SPAWN_INTERVAL * multiplier
			spawn_at(beacon, record, true)
		end
	end
end

-- Spends what the units that got nothing done were worth (`is_futile`) on units that can get across, at a beacon, as
-- the credit allows: one a second, each the hardest the budget allows being no more than the credit left, picked by
-- weight as the beacons pick. Credit short of anything that fits waits for more.
local function run_reroll()
	if reroll_credit <= 0 or clock < next_reroll_at then
		return
	end
	next_reroll_at = clock + REROLL_INTERVAL
	local at = standing_beacons()
	if #at == 0 or count_units() >= config.SCAVENGER_UNIT_CEILING then
		return
	end
	local headroom = math.min(budget(), reroll_credit)
	local air_around = enemy_air_exists()
	local options: { Spawn } = {}
	local total = 0
	for _, option in SPAWNS do
		local def = unit_defs.of(option)
		if
			def.kind == "unit"
			and can_cross(def)
			and difficulty_of(option.def_name) <= headroom
			and (air_around or is_anti_air_only(def) == false)
		then
			table.insert(options, option)
			total += option.weight
		end
	end
	if #options == 0 then
		return
	end
	local chosen = options[#options].def_name
	local roll = rng:NextNumber(0, total)
	for _, option in options do
		roll -= option.weight
		if roll <= 0 then
			chosen = option.def_name
			break
		end
	end
	local beacon = at[rng:NextInteger(1, #at)]
	local spot = find_spot(chosen, beacon.position, UNIT_RING_START)
	if spot == nil then
		return
	end
	toughen(state.create_entity(chosen, config.SCAVENGER_TEAM, spot.position, spot.facing, "active"))
	state.flush()
	reroll_credit -= difficulty_of(chosen)
end

-- Once the beacons start making things, more come at random gaps, while fewer than the limit stand. The first of
-- them, and any with none standing, is always a land one, so a player never faces a threat they have no way to reach.
local function run_beacon_schedule()
	-- with their boss out it is the end, and no more come
	if boss ~= nil or progress() < config.SCAVENGER_SPAWN_PROGRESS then
		return
	end
	local due = next_beacon_at
	if due == nil then
		next_beacon_at = clock + beacon_interval()
		return
	end
	if clock < due then
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

-- The nearest thing of a player's that `unit` can shoot at and has noticed. `avoid` is one that is not to be
-- considered, because there was no way to it.
local function find_target(unit: Entity, def: EntityDef, weapon: Weapon, avoid: EntityId?): Entity?
	if reach_of(def) == nil then
		return nil
	end
	local nearest: Entity? = nil
	local nearest_distance = config.SCAVENGER_DETECTION_RANGE
	for _, other in state.all() do
		if combat.is_enemy(unit, other) and combat.can_target(weapon, other) and other.id ~= avoid then
			local distance = geometry.distance_2d(unit.position, other.position)
			if distance <= nearest_distance and combat.spots(other, distance) then
				nearest = other
				nearest_distance = distance
			end
		end
	end
	return nearest
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

-- Goes after `target`: to its own spot at shooting range on the side it is coming from, and then an attack. Hunters
-- that all made for the target itself would stop in a clump at the front and leave the ones behind unable to get
-- into range. It goes there straight if it can walk the whole line, and otherwise by a route, so that it goes round
-- a cliff or a lake rather than into it. From its spot, the attack order walks it on if the ground is in the way of
-- its shot, and finds its way doing it, as any attack does.
--
-- It counts a route as good if it gets all the way, or, when there is water or a cliff between, as far as a place
-- within reach of the target, since it can shoot across. Otherwise it gives the target up for a while. A carrier with
-- nothing of its own to shoot goes to its spot and stays there, and its drones do the fighting.
local function hunt(unit: Entity, brain: Brain, def: EntityDef, target: Entity)
	local anchor = brain.route_anchor
	if
		brain.route_target == target.id
		and anchor ~= nil
		and unit.orders[1] ~= nil
		and clock < brain.route_until
		and geometry.distance_2d(anchor, target.position) <= ROUTE_TARGET_DRIFT
	then
		brain.useful_at = clock
		return
	end
	if clock < brain.next_path_at then
		return
	end

	local goal = hunt_slot(unit, def, target) or target.position
	local route: { Order }
	if pathfinder.has_straight_path(def, unit.position, goal) then
		route = { { kind = "move", position = goal } }
	else
		local path = plan_route(unit, def, goal)
		if path == nil then
			return
		end
		brain.next_path_at = clock + ROUTE_COOLDOWN

		local last = path.orders[#path.orders]
		local reach = reach_of(def) or 0
		local near_enough = path.complete
			or (last ~= nil and geometry.distance_2d(last.position or unit.position, target.position) <= reach)
		if near_enough == false then
			brain.hunting = false
			brain.route_target = nil
			brain.avoid_target = target.id
			brain.avoid_until = clock + AVOID_TIME
			brain.next_path_at = clock + PATH_RETRY_DELAY
			unit.orders = {}
			return
		end
		route = path.orders
	end

	local chain = table.clone(route)
	if def.weapons ~= nil then
		table.insert(chain, { kind = "attack", target_id = target.id })
	end
	orders.issue(unit, chain, false, false)
	-- it has a way to something it can shoot, which is getting something done
	brain.useful_at = clock
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
	local extent_x, extent_z = heightmap.half_extents()
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
			if distance < nearest_distance and combat.spots(other, distance) then
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
	if pathfinder.has_straight_path(def, unit.position, stage) then
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
			if pathfinder.has_straight_path(def, unit.position, point) then
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
			if pathfinder.has_straight_path(def, unit.position, point) then
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
			useful_at = clock,
			next_futile_check = clock + FUTILE_CHECK_INTERVAL,
			closest = math.huge,
			closest_target = nil,
		}
		brains[unit.id] = brain
	end
	return brain
end

-- Whether `unit` has got nothing done for `SCAVENGER_FUTILE_SECONDS`: not gone after anything it could reach (see
-- `hunt`), and not got any nearer the nearest thing of a player's than it had been. Every so often it looks at how near
-- that is; a new nearest thing starts the reckoning again from where it stands, and with nothing of a player's it could
-- turn on there is nothing to get done, so it is not held against it. Aircraft go wherever they like, and the boss is
-- never taken away.
local function is_futile(unit: Entity, brain: Brain, def: EntityDef): boolean
	if def.air ~= nil or unit == boss then
		return false
	end
	if clock >= brain.next_futile_check then
		brain.next_futile_check = clock + FUTILE_CHECK_INTERVAL
		local weapon = main_weapon(def)
		local target = if weapon ~= nil then nearest_enemy(unit, weapon, nil) else nil
		if target == nil then
			brain.useful_at = clock
		else
			local distance = geometry.distance_2d(unit.position, target.position)
			if target.id ~= brain.closest_target then
				brain.closest_target = target.id
				brain.closest = distance
			elseif distance <= brain.closest - config.SCAVENGER_FUTILE_PROGRESS then
				brain.closest = distance
				brain.useful_at = clock
			end
		end
	end
	return clock - brain.useful_at >= config.SCAVENGER_FUTILE_SECONDS
end

-- One unit making up its mind: hunt what it can reach, otherwise keep wandering.
local function think(unit: Entity, brain: Brain)
	local def = unit_defs.of(unit)
	brain.next_think = clock + THINK_INTERVAL

	-- stranded, say on an island with no way across: it is taken away, with no wreck, and what it was worth goes to
	-- making something that can get across (`run_reroll`)
	if is_futile(unit, brain, def) then
		reroll_credit += difficulty_of(unit.def_name)
		brains[unit.id] = nil
		state.mark_dead(unit)
		return
	end

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
		local target = find_target(unit, def, weapon, avoid)
		if target ~= nil then
			brain.hunting = true
			brain.seeking = false
			-- an aircraft flies over whatever is in the way, so it needs no route; a bomber's attack order is what
			-- makes it fly its bombing runs
			if def.air ~= nil then
				brain.route_target = nil
				local wanted: Order = { kind = "attack", target_id = target.id }
				if is_same_order(unit.orders[1], wanted) == false then
					orders.issue(unit, { wanted }, false, false)
				end
				return
			end
			hunt(unit, brain, def, target)
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

-- A manual-fire weapon, a nuclear silo's, fires only when it is told what at (`Weapon.manual_fire`), so the
-- scavengers tell theirs: one with a missile ready and nothing to do is ordered to attack the costliest thing of a
-- player's that it can reach (`difficulty_of`). Every THINK_INTERVAL seconds, like their units' thinking.
local function aim_manual_weapons()
	if clock < next_aim_at then
		return
	end
	next_aim_at = clock + THINK_INTERVAL
	for _, shooter in state.all() do
		if is_scavenger(shooter) == false or shooter.alive == false or shooter.state ~= "active" then
			continue
		end
		if #shooter.orders > 0 then
			continue
		end
		local def = unit_defs.of(shooter)
		if def.weapons == nil then
			continue
		end
		for index, weapon in def.weapons do
			if weapon.manual_fire ~= true then
				continue
			end
			if weapon.stockpile ~= nil and (shooter.weapon_stockpiles[index] or 0) < 1 then
				continue
			end
			local best: Entity? = nil
			local best_worth = -math.huge
			for _, other in state.all() do
				if
					combat.is_enemy(shooter, other)
					and combat.can_target(weapon, other)
					and geometry.distance_2d(shooter.position, other.position) <= weapon.range
					and combat.spots(other, geometry.distance_2d(shooter.position, other.position))
				then
					local worth = difficulty_of(other.def_name)
					if worth > best_worth then
						best = other
						best_worth = worth
					end
				end
			end
			if best ~= nil then
				shooter.orders = { { kind = "attack", position = nil, target_id = best.id } }
				break
			end
		end
	end
end

local function run_brains()
	for _, unit in state.all() do
		if is_scavenger(unit) == false or unit.alive == false or movement.is_mobile(unit) == false then
			continue
		end
		-- a drone is its carrier's to send out, and to call back
		if unit_defs.of(unit).drone == true then
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
-- Graverobber, and never a commander, and only within `SCAVENGER_REVIVE_RANGE` of a standing beacon: a wreck further
-- out lies as it is, keeping what progress it had, until a beacon goes up near it. With the server's ceiling of
-- scavenger units out it waits, full, for room; and whatever takes the wreck apart first, by reclaiming it, wins.
local function run_revival(delta: number)
	local near = standing_beacons()
	if #near == 0 then
		return
	end
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
			and unit_defs.of(other).drone ~= true
		then
			unit_count += 1
		end
	end

	for _, wreck_entity in wrecks do
		local wreck = wreck_entity.wreck
		if wreck == nil then
			continue
		end
		local in_range = false
		for _, beacon in near do
			if geometry.distance_2d(beacon.position, wreck_entity.position) <= config.SCAVENGER_REVIVE_RANGE then
				in_range = true
				break
			end
		end
		if in_range == false then
			continue
		end
		local source = unit_defs.get(wreck.source_def_name)
		if
			source.kind ~= "unit"
			or source.nametag == true
			or source.buildpower_cost <= 0
			or wreck.source_def_name == BOSS_DEF
		then
			continue
		end
		local cost = source.buildpower_cost
		wreck.resurrect_progress =
			math.min(cost, wreck.resurrect_progress + cost * delta / config.SCAVENGER_REVIVE_SECONDS)
		if wreck.resurrect_progress >= cost and unit_count < config.SCAVENGER_UNIT_CEILING then
			local raised = state.create_entity(
				wreck.source_def_name,
				config.SCAVENGER_TEAM,
				wreck_entity.position,
				wreck_entity.facing,
				"active"
			)
			toughen(raised)
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

	-- Scavengers have no economy: their weapons never want for metal or energy, however many are
	-- firing, or however much a single shot costs - a capacity-capped refill is not enough for
	-- something like the Calamity's 18000 energy per shot, well past any normal team's capacity.
	local team = state.get_team(config.SCAVENGER_TEAM)
	if team ~= nil then
		team.metal = math.huge
		team.energy = math.huge
	end

	local shown: number? = if enabled then round_significant(budget(), SHOWN_DIGITS) else nil
	if Workspace:GetAttribute(DIFFICULTY_ATTRIBUTE) ~= shown then
		Workspace:SetAttribute(DIFFICULTY_ATTRIBUTE, shown)
	end

	-- The game begins for the scavengers on the first step anything of a player's stands, so a start one of them has
	-- is never taken for free. With the gamemode off then, it is not opened later: turning it on part way just
	-- starts the schedule.
	if opened == false then
		for _, other in state.all() do
			if
				other.alive
				and other.kind ~= "wreck"
				and other.kind ~= "reclaimable"
				and is_scavenger(other) == false
			then
				opened = true
				break
			end
		end
		if opened and enabled then
			open()
		end
	end

	if enabled then
		-- the game's time is up: their boss comes, by a beacon if one stands, or in the middle of the map
		if boss == nil and progress() >= 1 then
			local standing = standing_beacons()
			summon_boss(if #standing > 0 then standing[rng:NextInteger(1, #standing)].position else Vector3.zero)
		end
		run_beacon_schedule()
		run_beacons()
		run_reroll()
		run_revival(delta)
	end
	-- a beacon that stops making things does not stop what it already made
	run_brains()
	aim_manual_weapons()
end

-- Sets the progress to what makes the budget `score` (the difficulty on the scavengers' readout) and returns the
-- progress and the budget that came of it. A score outside what the budget goes through, from its start to where it
-- stops growing, is taken to the nearest end.
local function set_difficulty(score: number): (number, number)
	-- the budget's curve run backwards
	local wanted = if score > config.SCAVENGER_BUDGET_START
		then math.min(math.log(score / config.SCAVENGER_BUDGET_START) / BUDGET_GROWTH, 1)
			^ (1 / config.SCAVENGER_BUDGET_SHAPE)
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

-- Makes the game take `multiple` times config.SCAVENGER_GAME_LENGTH to reach full progress, keeping the progress it
-- has now: under 1 the scavengers grow stronger sooner, which is what a lobby's difficulty sets.
local function set_pace(multiple: number)
	local now = progress()
	game_length = config.SCAVENGER_GAME_LENGTH * math.max(multiple, 0.01)
	set_progress(now)
end

-- Puts a beacon down now, whatever the schedule says. Returns whether there was room.
local function summon_beacon(): boolean
	return spawn_beacon(count_beacons() > 0)
end

-- What a beacon on the sea, or on the land, would make of its units, or its defences, if it made one now, and the
-- chance of each from 0 to 1, likeliest first. Whether there are aircraft about is taken as it stands, so what only
-- shoots at them is in it only while there are.
local function spawn_chances(
	defense: boolean,
	sea: boolean
): { { def_name: string, chance: number, difficulty: number } }
	local options, total = spawn_options(defense, budget(), sea, enemy_air_exists())
	local chances = {}
	for _, option in options do
		table.insert(chances, {
			def_name = option.def_name,
			chance = option.weight / total,
			difficulty = difficulty_of(option.def_name),
		})
	end
	table.sort(chances, function(a, b): boolean
		if a.chance ~= b.chance then
			return a.chance > b.chance
		end
		return a.def_name < b.def_name
	end)
	return chances
end

-- Called for everything that is gone. What was destroyed, and not only cleared away with the map, counts: a beacon
-- moves the game on (`lose_beacon`), and their boss wins it.
-- What the units that got nothing done were worth that is still to be spent on ones that can get across.
local function pending_reroll(): number
	return reroll_credit
end

-- Sets what everything the scavengers field from now on has in health, as a multiple of its def's: a match sets it
-- from its difficulty (`game_modes.Difficulty.health`).
local function set_health_multiplier(multiple: number)
	health_multiplier = math.max(multiple, 0.01)
end

local function forget(entity_id: EntityId)
	brains[entity_id] = nil
	local record = beacons[entity_id]
	if record ~= nil then
		lose_beacon(entity_id, record)
	end
	local fallen = boss
	if fallen ~= nil and fallen.id == entity_id and fallen.health <= 0 then
		defeat_boss()
	end
end

return table.freeze({
	init = init,
	tick = tick,
	set_enabled = set_enabled,
	is_enabled = is_enabled,
	set_pace = set_pace,
	set_health_multiplier = set_health_multiplier,
	pending_reroll = pending_reroll,
	summon_beacon = summon_beacon,
	force_beacon = force_beacon,
	progress = progress,
	set_progress = set_progress,
	set_difficulty = set_difficulty,
	budget = budget,
	spawn_chances = spawn_chances,
	forget = forget,
})
