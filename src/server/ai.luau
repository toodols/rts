-- A computer player. Each team it plays has a brain of its own, which looks the team over once a second and gives its
-- builders, labs and army their orders through the same `orders.issue` and `production.enqueue` a player's commands
-- come through, so it plays by the rules everything else does: it pays for what it builds, walks where it goes and can
-- be beaten.
--
-- It sees the map through a danger field (danger_field.luau): where the enemy's weapons reach, and how hard. Its
-- builders only go to build, and its rezbots to raise a wreck, where the field is quiet and by a way that is quiet too;
-- a builder whose errand turns dangerous on the way drops it, one caught where it is not or taking hits out on the map
-- runs for home; and its army only attacks where what it would face is well short of what it has.
--
-- What it builds, in the order it looks at it for each builder with nothing to do:
--
-- - With only a commander it opens: OPENING_EXTRACTORS metal extractors on the spots nearest home, OPENING_TURBINES wind
--   turbines, and then a lab, a bot lab or a vehicle lab (`choose_line`).
-- - A lab of its line, if it has none; never a second of any lab.
-- - Energy, when it is stalling: wind turbines, advanced solar collectors once the team makes ADVANCED_SOLAR_ENERGY,
--   and fusion reactors once it makes FUSION_ENERGY and has an advanced constructor.
-- - Its line's advanced lab, once it makes T2_METAL_INCOME metal.
-- - Metal extractors on the free spots out on the map, each builder that goes out of the base with an escort.
-- - Energy, to keep up with its metal (ENERGY_PER_METAL).
-- - A guard beside every metal extractor.
-- - With an advanced constructor, advanced extractors over the plain ones.
-- - Anti-air, once the enemy has AIR_THREAT_COUNT aircraft up.
-- - Energy storage while its energy piles up, until it can hold STORAGE_SECONDS of its income, and from there energy
--   converters to turn what piles up into metal. What they burn counts as energy it wants, so it builds more energy
--   (advanced solar collectors, then fusion) to feed them, and grows on energy once the metal spots run out.
-- - Construction turrets beside its labs, now and then as its income grows.
--
-- Anything of the economy's goes up beside another of its kind, so wind turbines stand in a block, fusion reactors in
-- another and construction turrets in a third (`cluster_site`); a defence and an extractor go where they are needed.
--
-- Its labs keep enough constructors, a rezbot or two while there are wrecks lying about, anti-air while the enemy flies,
-- and otherwise a mix of whatever fights that its income can pay for (`fighter_for`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local spots = require(ReplicatedStorage.Shared.spots)
local starts = require(ReplicatedStorage.Shared.starts)

local state = require(script.Parent.state)
local orders = require(script.Parent.orders)
local placement = require(script.Parent.placement)
local production = require(script.Parent.production)
local spawning = require(script.Parent.spawning)
local players = require(script.Parent.players)
local alliances = require(script.Parent.alliances)
local reclaim = require(script.Parent.reclaim)
local resurrection = require(script.Parent.resurrection)
local campaign = require(script.Parent.campaign)
local danger_field = require(script.Parent.danger_field)

type Entity = types.Entity
type EntityDef = types.EntityDef
type EntityId = types.EntityId
type Order = types.Order
type OrderKind = types.OrderKind
type Team = types.Team
type TeamId = types.TeamId
type Field = danger_field.Field

-- Which kind of lab it builds its army from.
type Line = "bot" | "vehicle"

-- What the army is doing: waiting at its rally point, on its way to an enemy target, or seeing off a raid at home.
type Mode = "gather" | "attack" | "defend"

-- What a def is, to the AI.
type Role = {
	-- a unit that builds: a commander or a constructor
	builder: boolean,
	-- a builder that can put up the advanced economy (advanced extractors, fusion reactors)
	advanced: boolean,
	rezbot: boolean,
	factory: boolean,
	extractor: boolean,
	-- has a weapon (or drones) that can be turned on the ground, and one that can be turned on aircraft
	hits_ground: boolean,
	hits_air: boolean,
	-- has a weapon made for shooting aircraft down
	anti_air: boolean,
}

-- A building one of its builders has been sent to put up and has not started yet.
type Plan = {
	def_name: string,
	position: Vector3,
	facing: number,
	half: Vector2,
}

-- The strip in front of a lab's doorway that its units drive out through, which nothing is built on.
type Lane = {
	center: Vector3,
	half: Vector2,
}

-- A building to put up, and where.
type Task = {
	def_name: string,
	position: Vector3,
	facing: number,
}

-- How the team's economy stands.
type Economy = {
	metal_income: number,
	-- what its finished converters make of metal at their full rate, which metal_income leaves out
	converted_metal: number,
	energy_income: number,
	energy_capacity: number,
	-- how full its energy store is, 0 to 1
	energy_fill: number,
	energy_stalling: boolean,
	energy_overflowing: boolean,
	metal_overflowing: boolean,
	metal_short: boolean,
}

-- The team, looked over at the start of a thought.
type Census = {
	commander: Entity?,
	-- units that build, the commander among them
	builders: { Entity },
	factories: { Entity },
	-- its buildings, finished or not
	structures: { Entity },
	by_def: { [string]: { Entity } },
	-- how many of each def it has, finished or not, with what its labs have queued
	counts: { [string]: number },
	-- how many of each def stand unfinished
	unfinished: { [string]: number },
	extractors: { Entity },
	ground_defenses: { Entity },
	air_defenses: { Entity },
	army: { Entity },
	rezbots: { Entity },
	anti_air_units: number,
	advanced_builders: number,
	plans: { Plan },
	planned: { [string]: number },
	lanes: { Lane },
	-- every metal spot something stands on, anyone's
	taken_spots: { Vector3 },
	wrecks: { Entity },
	reclaimables: { Entity },
	enemy_structures: { Entity },
	enemy_units: { Entity },
}

type Brain = {
	team: TeamId,
	home: Vector3,
	-- the way from home toward the middle of the map, flat and of length 1
	forward: Vector3,
	line: Line?,
	field: Field,
	rng: Random,
	next_think: number,
	next_field: number,
	opened: boolean,
	-- builders given something to help with for want of anything better, and when they may be looked at again
	assisting: { [EntityId]: number },
	-- builders out on the map, beyond the base, which want an escort
	expanding: { [EntityId]: boolean },
	-- builders that ran from danger, and until when they are left to get home
	fleeing: { [EntityId]: number },
	-- each builder's health at the last thought, to tell when it is being hit
	health: { [EntityId]: number },
	-- how many builders other than the commander it has lost
	builders_lost: number,
	-- each escort, and the builder it guards
	escorts: { [EntityId]: EntityId },
	-- each rezbot, and the wreck or rock it was sent to
	salvaging: { [EntityId]: EntityId },
	-- each army unit, and where it was last sent
	goals: { [EntityId]: Vector3 },
	mode: Mode,
	target: EntityId?,
	next_attack_at: number,
	-- buildings with no room left beside them for another of their kind
	full: { [EntityId]: boolean },
}

-- How often a brain thinks, and how often its danger field is worked out again.
local THINK_INTERVAL = 1
local FIELD_INTERVAL = 2
-- How long a builder that was given something to help with is left at it before it is looked at again.
local ASSIST_RECHECK = 6

-- Danger, in the field's units (what the enemy that reaches there is worth), that a place and the way to it have to be
-- under for a builder or a rezbot to be sent there, that makes one already on its way drop its errand, and that a
-- builder out on the map runs from. The first is about the worth of a single light raider.
local SAFE_DANGER = 20
local ABORT_DANGER = 30
local FLEE_DANGER = 40
local FLEE_SECONDS = 12

-- The opening, with only a commander.
local OPENING_EXTRACTORS = 3
local OPENING_TURBINES = 4

-- The base: the commander stays within BASE_RADIUS of home, and a builder sent further gets an escort.
local BASE_RADIUS = 70
local ESCORTS_PER_BUILDER = 2

-- Income thresholds, metal and energy a second.
local T2_METAL_INCOME = 40
local ADVANCED_SOLAR_ENERGY = 200
local FUSION_ENERGY = 1000
-- The energy income it wants for each metal of income: what its labs spend the two in, give or take.
local ENERGY_PER_METAL = 15
-- How many enemy aircraft make it build anti-air, and how many anti-air units it wants for each.
local AIR_THREAT_COUNT = 4
local ANTI_AIR_PER_AIRCRAFT = 0.75
local AIR_DEFENSES_MAX = 12
-- Converters burn only the energy over config.CONVERTER_THRESHOLD of its store, so it first builds energy stores
-- while its energy piles up (the store over PILING_FILL full), until it can hold STORAGE_SECONDS of its energy income
-- and at least CONVERTER_STORAGE, or has ENERGY_STORES_MAX of them; from there it builds converters, advanced ones once
-- it makes ADVANCED_CONVERTER_ENERGY, no more than CONVERTERS_AT_ONCE at a time.
local PILING_FILL = 0.7
local STORAGE_SECONDS = 12
local CONVERTER_STORAGE = 6000
local ENERGY_STORES_MAX = 6
local ADVANCED_CONVERTER_ENERGY = 1200
local CONVERTERS_AT_ONCE = 2
local CONVERTER_DEFS = { "energy_converter", "advanced_energy_converter", "epic_energy_converter" }
-- Construction turrets: none until it makes TURRET_INCOME metal, then one for every METAL_PER_TURRET of it up to
-- TURRETS_MAX, one at a time, and advanced ones once it makes ADVANCED_TURRET_INCOME.
local TURRET_INCOME = 12
local METAL_PER_TURRET = 12
local TURRETS_MAX = 8
local ADVANCED_TURRET_INCOME = 60

-- Constructors its labs keep: plain ones from 2 up to 8 as the income grows, and advanced ones from 1 up to 4.
local CONSTRUCTORS_MIN = 2
local CONSTRUCTORS_MAX = 8
local METAL_PER_CONSTRUCTOR = 6
local ADVANCED_CONSTRUCTORS_MAX = 4
local METAL_PER_ADVANCED_CONSTRUCTOR = 25
-- Rezbots: none without wrecks to raise, and then one for every few up to a few.
local WRECKS_PER_REZBOT = 6
local REZBOTS_MAX = 4
-- A lab keeps this many things queued.
local FACTORY_QUEUE = 2
-- It fields what costs no more than this many seconds of its metal income, and not what is worth less than
-- FODDER_SHARE of the dearest of that.
local AFFORD_SECONDS = 20
local FODDER_SHARE = 0.15

-- Siting. Buildings go RING_STEP apart on rings round where they are wanted, no further than MAX_SITE_TRIES places
-- being looked at a time. Nothing is built within SPOT_CLEARANCE of a metal spot but an extractor, nor in the LANE_LENGTH
-- in front of a lab's doorway.
local RING_STEP = 6
local MAX_SITE_TRIES = 90
local SPOT_CLEARANCE = 3
local LANE_LENGTH = 18
local LAB_OFFSET = 18
local LAB_SEARCH_RADIUS = 60
-- A new block of the economy starts this far behind home, away from the enemy.
local ECONOMY_OFFSET = 22
local CLUSTER_SEARCH_RADIUS = 80
-- A block's members are looked at, nearest home first, this many at most.
local CLUSTER_ANCHORS = 20
-- A guard goes this far from the extractor it guards, and an extractor counts as guarded with one this close.
local GUARD_RING_INNER = 6
local GUARD_RING_OUTER = 14
local GUARDED_RADIUS = 16
-- Anti-air goes this far from what it covers.
local AIR_RING_INNER = 8
local AIR_RING_OUTER = 22

-- Routes. A thought may ask for this many, each settling no more than PATH_MAX_EXPANSIONS cells.
local PATHS_PER_THINK = 6
local PATH_MAX_EXPANSIONS = 4000

-- The army. It attacks once it is worth ATTACK_BASE plus ATTACK_SECONDS of the metal income, and only something the
-- danger round which is under its worth over ATTACK_SUPERIORITY; it pulls back to regroup for REGROUP_SECONDS when
-- the danger where it stands is over RETREAT_RATIO of its worth. An enemy that has come within DEFEND_RADIUS of home,
-- or ALERT_RADIUS of an extractor, is seen off first.
local ATTACK_BASE = 600
local ATTACK_SECONDS = 40
local ATTACK_SUPERIORITY = 1.5
local RETREAT_RATIO = 1.5
local REGROUP_SECONDS = 30
local DEFEND_RADIUS = 110
local ALERT_RADIUS = 40
local TARGET_DANGER_RADIUS = 24
local RALLY_OFFSET = 40
-- An army unit is sent again when where it should be has moved this far from where it was sent.
local GOAL_DRIFT = 25
-- How near its rally point a waiting unit has to be.
local RALLY_SLACK = 25

local LABS: { [Line]: string } = { bot = "bot_lab", vehicle = "vehicle_lab" }
local ADVANCED_LABS: { [Line]: string } = { bot = "advanced_bot_lab", vehicle = "advanced_vehicle_lab" }

-- What makes energy, which is built in blocks of its own kind like the rest of the economy.
local ENERGY_DEFS: { [string]: boolean } = {
	wind_turbine = true,
	solar_collector = true,
	advanced_solar_collector = true,
	fusion_reactor = true,
	advanced_fusion_reactor = true,
}

-- The eight places beside a building, the four sides before the corners.
local NEIGHBOURS: { Vector2 } = {
	Vector2.new(1, 0),
	Vector2.new(-1, 0),
	Vector2.new(0, 1),
	Vector2.new(0, -1),
	Vector2.new(1, 1),
	Vector2.new(-1, 1),
	Vector2.new(1, -1),
	Vector2.new(-1, -1),
}

local brains: { [TeamId]: Brain } = {}
local clock = 0
local paths_left = 0
-- How many opponents to put down once the game is under way, and whether that has been done.
local opponents_wanted = 0
local opponents_placed = false
local roles: { [string]: Role } = {}

local function role_of(def_name: string): Role
	local cached = roles[def_name]
	if cached ~= nil then
		return cached
	end
	local def = unit_defs.get(def_name)
	local options = def.build_options or {}
	local ground_reach, air_reach = danger_field.reaches_of(def)
	local anti_air = false
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			if weapon.anti_air == true or weapon.target_layer == "air" then
				anti_air = true
			end
		end
	end
	local mobile_builder = def.kind == "unit" and def.air == nil and def.buildpower ~= nil and def.assisting
	local role: Role = {
		builder = mobile_builder and (table.find(options, "metal_extractor") ~= nil or table.find(
			options,
			"advanced_metal_extractor"
		) ~= nil),
		advanced = table.find(options, "advanced_metal_extractor") ~= nil,
		rezbot = def.kind == "unit" and def.resurrecting,
		factory = unit_defs.is_factory(def),
		extractor = def.requires_metal_spot == true,
		hits_ground = ground_reach ~= nil,
		hits_air = air_reach ~= nil,
		anti_air = anti_air,
	}
	roles[def_name] = role
	return role
end

local function can_build(builder: Entity, def_name: string): boolean
	local options = unit_defs.of(builder).build_options
	return options ~= nil and table.find(options, def_name) ~= nil and campaign.can_build(builder.team, def_name)
end

local function is_commander(entity: Entity): boolean
	return unit_defs.of(entity).nametag == true
end

local function in_progress(census: Census, def_name: string): number
	return (census.planned[def_name] or 0) + (census.unfinished[def_name] or 0)
end

local function count_of(census: Census, def_name: string): number
	return (census.counts[def_name] or 0) + (census.planned[def_name] or 0)
end

-- Its buildings of `def_name`, finished or not.
local function buildings_of(census: Census, def_name: string): { Entity }
	return census.by_def[def_name] or {}
end

local function bump(tally: { [string]: number }, def_name: string)
	tally[def_name] = (tally[def_name] or 0) + 1
end

-- The strip in front of the doorway of a lab of `def_name` at `position`, turned to `facing`.
local function lane_of(def_name: string, position: Vector3, facing: number): Lane
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(unit_defs.get(def_name)), facing)
	local out = Vector3.new(math.sin(facing), 0, math.cos(facing))
	local edge = math.abs(out.X) * half.X + math.abs(out.Z) * half.Y
	local lane_half = if math.abs(out.X) > 0.5
		then Vector2.new(LANE_LENGTH / 2, half.Y + 2)
		else Vector2.new(half.X + 2, LANE_LENGTH / 2)
	return { center = position + out * (edge + LANE_LENGTH / 2), half = lane_half }
end

local function add_plan(census: Census, def_name: string, position: Vector3, facing: number)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(unit_defs.get(def_name)), facing)
	table.insert(census.plans, { def_name = def_name, position = position, facing = facing, half = half })
	bump(census.planned, def_name)
	if role_of(def_name).factory then
		table.insert(census.lanes, lane_of(def_name, position, facing))
	end
end

-- Looks the team, and everything round it, over.
local function take_census(brain: Brain): Census
	local census: Census = {
		commander = nil,
		builders = {},
		factories = {},
		structures = {},
		by_def = {},
		counts = {},
		unfinished = {},
		extractors = {},
		ground_defenses = {},
		air_defenses = {},
		army = {},
		rezbots = {},
		anti_air_units = 0,
		advanced_builders = 0,
		plans = {},
		planned = {},
		lanes = {},
		taken_spots = {},
		wrecks = {},
		reclaimables = {},
		enemy_structures = {},
		enemy_units = {},
	}
	for _, entity in state.all() do
		if entity.alive == false then
			continue
		end
		if entity.kind == "wreck" then
			table.insert(census.wrecks, entity)
			continue
		end
		if entity.kind == "reclaimable" then
			local yield = entity.yield
			if yield ~= nil and yield.metal_left > 0 then
				table.insert(census.reclaimables, entity)
			end
			continue
		end
		local role = role_of(entity.def_name)
		if role.extractor then
			table.insert(census.taken_spots, entity.position)
		end
		if entity.team ~= brain.team then
			if
				entity.team ~= 0
				and entity.state == "active"
				and alliances.are_allied(brain.team, entity.team) == false
			then
				table.insert(if entity.kind == "building" then census.enemy_structures else census.enemy_units, entity)
			end
			continue
		end

		bump(census.counts, entity.def_name)
		if entity.state == "blueprint" then
			bump(census.unfinished, entity.def_name)
		end
		for _, queued in entity.queue do
			bump(census.counts, queued)
		end
		for _, order in entity.orders do
			if order.kind == "build" and order.def_name ~= nil and order.position ~= nil and order.facing ~= nil then
				add_plan(census, order.def_name, order.position, order.facing)
			end
		end

		if entity.kind == "building" then
			table.insert(census.structures, entity)
			local list = census.by_def[entity.def_name]
			if list == nil then
				list = {}
				census.by_def[entity.def_name] = list
			end
			table.insert(list, entity)
			if role.factory then
				table.insert(census.lanes, lane_of(entity.def_name, entity.position, entity.facing))
				if entity.state == "active" then
					table.insert(census.factories, entity)
				end
			end
			if entity.state == "active" then
				if role.extractor then
					table.insert(census.extractors, entity)
				end
				if role.hits_ground and entity.def_name ~= "wall" then
					table.insert(census.ground_defenses, entity)
				end
				if role.anti_air then
					table.insert(census.air_defenses, entity)
				end
			end
			continue
		end

		if entity.state ~= "active" or unit_defs.of(entity).drone == true then
			continue
		end
		if is_commander(entity) then
			census.commander = entity
		end
		if role.builder then
			table.insert(census.builders, entity)
			if role.advanced then
				census.advanced_builders += 1
			end
		elseif role.rezbot then
			table.insert(census.rezbots, entity)
		elseif role.hits_ground or role.hits_air then
			table.insert(census.army, entity)
			if role.anti_air then
				census.anti_air_units += 1
			end
		end
	end
	return census
end

local function read_economy(team: Team, census: Census): Economy
	local converted = 0
	for _, def_name in CONVERTER_DEFS do
		local conversion = unit_defs.get(def_name).energy_conversion
		for _, converter in buildings_of(census, def_name) do
			if conversion ~= nil and converter.state == "active" then
				converted += conversion.metal_per_second
			end
		end
	end
	return {
		metal_income = team.metal_income,
		converted_metal = converted,
		energy_income = team.energy_income,
		energy_capacity = team.energy_capacity,
		energy_fill = team.energy / math.max(1, team.energy_capacity),
		energy_stalling = team.energy < team.energy_capacity * 0.1 and team.energy_expense >= team.energy_revenue * 0.9,
		energy_overflowing = team.energy > team.energy_capacity * 0.9 and team.energy_revenue >= team.energy_expense,
		metal_overflowing = team.metal > team.metal_capacity * 0.9,
		metal_short = team.metal < team.metal_capacity * 0.05 and team.metal_expense > team.metal_revenue,
	}
end

-- The most danger on the way from `from` to `to`, leaving out the cell it sets out from, so that one standing
-- somewhere the danger just touches can still be sent away from it.
local function route_danger(brain: Brain, from: Vector3, to: Vector3): number
	local offset = geometry.flatten(to - from)
	if offset.Magnitude <= danger_field.CELL_STUDS then
		return danger_field.at(brain.field, to)
	end
	return danger_field.peak_along(brain.field, from + offset.Unit * danger_field.CELL_STUDS, to)
end

-- The most danger on the way `unit` would go through the moves of `chain` and on to `goal`.
local function chain_danger(brain: Brain, unit: Entity, chain: { Order }, goal: Vector3): number
	local from = unit.position
	local peak = 0
	for _, order in chain do
		local position = order.position
		if order.kind == "move" and position ~= nil then
			peak = math.max(peak, route_danger(brain, from, position))
			from = position
		end
	end
	return math.max(peak, route_danger(brain, from, goal))
end

-- Whether a building of `def_name` could go up at `center`, turned to `facing`: it is on the map, somewhere quiet, off
-- the metal spots unless it is an extractor, clear of every lab's doorway and of what its builders have been sent to put
-- up, and, for a lab, with its own doorway clear; and the ground and what stands on it let it.
local function site_clear(brain: Brain, census: Census, def_name: string, center: Vector3, facing: number): boolean
	if heightmap.in_bounds(center.X, center.Z) == false then
		return false
	end
	if danger_field.at(brain.field, center) >= SAFE_DANGER then
		return false
	end
	local def = unit_defs.get(def_name)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
	for _, plan in census.plans do
		if geometry.aabb_overlap(center, half, plan.position, plan.half, 0) then
			return false
		end
	end
	for _, lane in census.lanes do
		if geometry.aabb_overlap(center, half, lane.center, lane.half, 0) then
			return false
		end
	end
	if spots.for_def(def) == nil then
		local reach = math.max(half.X, half.Y) + SPOT_CLEARANCE
		if metal_spots.nearest(center.X, center.Z, reach, nil) ~= nil then
			return false
		end
	end
	if role_of(def_name).factory then
		local lane = lane_of(def_name, center, facing)
		if heightmap.in_bounds(lane.center.X, lane.center.Z) == false then
			return false
		end
		for _, building in census.structures do
			if
				geometry.aabb_overlap(
					lane.center,
					lane.half,
					building.position,
					placement.half_extents_for(building),
					0
				)
			then
				return false
			end
		end
		for _, plan in census.plans do
			if geometry.aabb_overlap(lane.center, lane.half, plan.position, plan.half, 0) then
				return false
			end
		end
	end
	return placement.can_place(def_name, center, facing, nil, brain.team)
end

-- The first place for `def_name` on rings round `around`, from `inner` out to `outer`.
local function ring_site(
	brain: Brain,
	census: Census,
	def_name: string,
	around: Vector3,
	inner: number,
	outer: number,
	facing: number
): Task?
	local tries = 0
	for radius = inner, outer, RING_STEP do
		local count = if radius <= 0 then 1 else math.max(6, math.floor(math.pi * 2 * radius / RING_STEP))
		local first_angle = brain.rng:NextNumber(0, math.pi * 2)
		for step = 0, count - 1 do
			local angle = first_angle + step * (math.pi * 2 / count)
			local x = around.X + math.cos(angle) * radius
			local z = around.Z + math.sin(angle) * radius
			if heightmap.in_bounds(x, z) == false then
				continue
			end
			tries += 1
			if tries > MAX_SITE_TRIES then
				return nil
			end
			local center = placement.resolve_center(def_name, x, z, facing)
			if center ~= nil and site_clear(brain, census, def_name, center, facing) then
				return { def_name = def_name, position = center, facing = facing }
			end
		end
	end
	return nil
end

-- Where a new block of `def_name` starts: construction turrets beside the first lab, and the rest of the economy
-- behind home, away from the enemy.
local function seed_of(brain: Brain, census: Census, def_name: string): Vector3
	if def_name == "construction_turret" or def_name == "advanced_construction_turret" then
		local lab = census.factories[1]
		if lab ~= nil then
			local out = Vector3.new(math.sin(lab.facing), 0, math.cos(lab.facing))
			local right = Vector3.new(-out.Z, 0, out.X)
			local half = placement.half_extents_for(lab)
			return lab.position + right * (math.max(half.X, half.Y) + 4)
		end
	end
	local behind = brain.home - brain.forward * ECONOMY_OFFSET
	if
		def_name == "energy_storage"
		or def_name == "energy_converter"
		or def_name == "advanced_energy_converter"
		or def_name == "metal_storage"
	then
		-- off to one side of the energy, so the two blocks grow apart
		behind += Vector3.new(-brain.forward.Z, 0, brain.forward.X) * ECONOMY_OFFSET
	end
	return behind
end

-- A place for `def_name` beside another of its kind, nearest home first, or where a new block of it starts if there is
-- no room beside any.
local function cluster_site(brain: Brain, census: Census, def_name: string): Task?
	local half = unit_defs.footprint_half_extents(unit_defs.get(def_name))
	local anchors: { { position: Vector3, half: Vector2, id: EntityId? } } = {}
	for _, building in buildings_of(census, def_name) do
		if brain.full[building.id] ~= true then
			table.insert(
				anchors,
				{ position = building.position, half = placement.half_extents_for(building), id = building.id }
			)
		end
	end
	for _, plan in census.plans do
		if plan.def_name == def_name then
			table.insert(anchors, { position = plan.position, half = plan.half, id = nil })
		end
	end
	table.sort(anchors, function(a, b): boolean
		return geometry.distance_2d(a.position, brain.home) < geometry.distance_2d(b.position, brain.home)
	end)
	for index, anchor in anchors do
		if index > CLUSTER_ANCHORS then
			break
		end
		local room = false
		for _, side in NEIGHBOURS do
			local x = anchor.position.X + side.X * (anchor.half.X + half.X)
			local z = anchor.position.Z + side.Y * (anchor.half.Y + half.Y)
			local center = placement.resolve_center(def_name, x, z, 0)
			if center == nil then
				continue
			end
			if site_clear(brain, census, def_name, center, 0) then
				return { def_name = def_name, position = center, facing = 0 }
			end
			-- somewhere a plan may yet free up, or the enemy may yet leave, is not given up on
			if danger_field.at(brain.field, center) >= SAFE_DANGER then
				room = true
			end
		end
		local id = anchor.id
		if room == false and id ~= nil then
			brain.full[id] = true
		end
	end
	return ring_site(brain, census, def_name, seed_of(brain, census, def_name), 0, CLUSTER_SEARCH_RADIUS, 0)
end

-- Whether an extractor of anyone's, or one its own builders have been sent to put up, is on the metal spot at `position`.
local function spot_taken(census: Census, position: Vector3): boolean
	for _, taken in census.taken_spots do
		if geometry.distance_2d(taken, position) < 1 then
			return true
		end
	end
	for _, plan in census.plans do
		if role_of(plan.def_name).extractor and geometry.distance_2d(plan.position, position) < 1 then
			return true
		end
	end
	return false
end

-- The best free, quiet metal spot for `builder` to put an extractor on, by a quiet way, within `max_distance` of home
-- if that is given: near the builder and home, and rich ones first.
local function extractor_task(brain: Brain, census: Census, builder: Entity, max_distance: number?): Task?
	local def_name = "metal_extractor"
	if can_build(builder, def_name) == false then
		return nil
	end
	local builder_def = unit_defs.of(builder)
	local candidates: { { position: Vector3, score: number } } = {}
	for _, spot in metal_spots.all() do
		for _, position in spot.positions do
			local from_home = geometry.distance_2d(position, brain.home)
			if max_distance ~= nil and from_home > max_distance then
				continue
			end
			if builder_def.max_water_depth <= 0 and heightmap.water_depth(position.X, position.Z) > 0 then
				continue
			end
			if spot_taken(census, position) then
				continue
			end
			if danger_field.peak_near(brain.field, position, GUARDED_RADIUS) >= SAFE_DANGER then
				continue
			end
			local score = geometry.distance_2d(builder.position, position) + from_home * 0.5 - spot.multiplier * 10
			table.insert(candidates, { position = position, score = score })
		end
	end
	table.sort(candidates, function(a, b): boolean
		return a.score < b.score
	end)
	local tried = 0
	for _, candidate in candidates do
		if route_danger(brain, builder.position, candidate.position) >= SAFE_DANGER then
			continue
		end
		tried += 1
		if tried > 6 then
			break
		end
		local center = placement.ground_center(def_name, candidate.position.X, candidate.position.Z)
		if placement.can_place(def_name, center, 0, nil, brain.team) then
			return { def_name = def_name, position = center, facing = 0 }
		end
	end
	return nil
end

-- A plain extractor of its own, somewhere quiet, to build an advanced one over.
local function upgrade_task(brain: Brain, census: Census, builder: Entity): Task?
	local def_name = "advanced_metal_extractor"
	if can_build(builder, def_name) == false then
		return nil
	end
	local best: Entity? = nil
	local best_distance = math.huge
	for _, extractor in census.extractors do
		if extractor.def_name ~= "metal_extractor" then
			continue
		end
		if danger_field.peak_near(brain.field, extractor.position, GUARDED_RADIUS) >= SAFE_DANGER then
			continue
		end
		local upgrading = false
		for _, plan in census.plans do
			if plan.def_name == def_name and geometry.distance_2d(plan.position, extractor.position) < 1 then
				upgrading = true
				break
			end
		end
		for _, unfinished in buildings_of(census, def_name) do
			if geometry.distance_2d(unfinished.position, extractor.position) < 1 then
				upgrading = true
				break
			end
		end
		if upgrading then
			continue
		end
		local distance = geometry.distance_2d(builder.position, extractor.position)
		if distance < best_distance then
			best = extractor
			best_distance = distance
		end
	end
	if best == nil then
		return nil
	end
	local center = placement.ground_center(def_name, best.position.X, best.position.Z)
	if placement.can_place(def_name, center, 0, nil, brain.team) == false then
		return nil
	end
	return { def_name = def_name, position = center, facing = 0 }
end

-- An extractor of its own with nothing to guard it and nothing on its way, and a guard beside it, on the side toward
-- the enemy if there is room there.
local function guard_task(brain: Brain, census: Census, builder: Entity): Task?
	local def_name = "guard"
	if can_build(builder, def_name) == false then
		return nil
	end
	local best: Entity? = nil
	local best_distance = math.huge
	for _, extractor in census.extractors do
		local guarded = false
		for _, defense in census.ground_defenses do
			if geometry.distance_2d(defense.position, extractor.position) <= GUARDED_RADIUS then
				guarded = true
				break
			end
		end
		if guarded == false then
			for _, plan in census.plans do
				if
					role_of(plan.def_name).hits_ground
					and geometry.distance_2d(plan.position, extractor.position) <= GUARDED_RADIUS
				then
					guarded = true
					break
				end
			end
		end
		if guarded or danger_field.peak_near(brain.field, extractor.position, GUARDED_RADIUS) >= SAFE_DANGER then
			continue
		end
		local distance = geometry.distance_2d(builder.position, extractor.position)
		if distance < best_distance then
			best = extractor
			best_distance = distance
		end
	end
	if best == nil then
		return nil
	end
	local toward = geometry.flatten(-best.position)
	local ahead = if toward.Magnitude > 1 then best.position + toward.Unit * GUARD_RING_INNER else best.position
	return ring_site(brain, census, def_name, ahead, 0, GUARD_RING_OUTER, 0)
end

-- Anti-air, beside whatever of its own is furthest from the anti-air it has.
local function air_defense_task(brain: Brain, census: Census, builder: Entity, economy: Economy): Task?
	local def_name = if can_build(builder, "eradicator") and economy.metal_income >= 20
		then "eradicator"
		elseif can_build(builder, "thistle") then "thistle"
		else nil
	if def_name == nil then
		return nil
	end
	local covered: { Vector3 } = {}
	for _, defense in census.air_defenses do
		table.insert(covered, defense.position)
	end
	for _, plan in census.plans do
		if role_of(plan.def_name).anti_air then
			table.insert(covered, plan.position)
		end
	end
	local best: Entity? = nil
	local best_gap = -1
	for _, building in census.structures do
		if building.state ~= "active" then
			continue
		end
		local role = role_of(building.def_name)
		if role.factory == false and ENERGY_DEFS[building.def_name] ~= true and role.extractor == false then
			continue
		end
		local gap = math.huge
		for _, position in covered do
			gap = math.min(gap, geometry.distance_2d(position, building.position))
		end
		if gap > best_gap then
			best = building
			best_gap = gap
		end
	end
	if best == nil then
		return nil
	end
	return ring_site(brain, census, def_name, best.position, AIR_RING_INNER, AIR_RING_OUTER, 0)
end

-- What `builder` should build for energy now: wind turbines until the team makes ADVANCED_SOLAR_ENERGY, advanced solar
-- collectors from there, and fusion reactors once it makes FUSION_ENERGY and has an advanced constructor to build them,
-- which is then all the energy that is built but in a stall.
local function energy_choice(census: Census, economy: Economy, builder: Entity): string?
	if economy.energy_income >= FUSION_ENERGY and census.advanced_builders > 0 then
		if can_build(builder, "fusion_reactor") then
			return "fusion_reactor"
		end
		if economy.energy_stalling == false then
			return nil
		end
	end
	if economy.energy_income >= ADVANCED_SOLAR_ENERGY then
		if can_build(builder, "advanced_solar_collector") then
			return "advanced_solar_collector"
		end
		if economy.energy_stalling == false then
			return nil
		end
	end
	if can_build(builder, "wind_turbine") then
		return "wind_turbine"
	end
	if can_build(builder, "solar_collector") then
		return "solar_collector"
	end
	return nil
end

local function energy_in_progress(census: Census): number
	local total = 0
	for def_name in ENERGY_DEFS do
		total += in_progress(census, def_name)
	end
	return total
end

local function energy_task(brain: Brain, census: Census, economy: Economy, builder: Entity): Task?
	local def_name = energy_choice(census, economy, builder)
	if def_name == nil then
		return nil
	end
	return cluster_site(brain, census, def_name)
end

-- The energy a second its converters burn at their full rate, the ones not finished or not started among them.
local function conversion_draw(census: Census): number
	local total = 0
	for _, def_name in CONVERTER_DEFS do
		local conversion = unit_defs.get(def_name).energy_conversion
		if conversion ~= nil then
			total += count_of(census, def_name) * conversion.energy_per_second
		end
	end
	return total
end

-- The energy income it wants: enough for its metal (ENERGY_PER_METAL), and enough to keep its converters running.
local function energy_wanted(census: Census, economy: Economy): number
	return economy.metal_income * ENERGY_PER_METAL + conversion_draw(census)
end

-- While its energy piles up: another energy store if it cannot yet hold enough for converters to work from, and
-- otherwise a converter to turn what piles up into metal, so long as it has room for the metal.
local function conversion_task(brain: Brain, census: Census, economy: Economy, builder: Entity): Task?
	if economy.energy_fill < PILING_FILL and economy.energy_overflowing == false then
		return nil
	end
	local store_wanted = math.max(CONVERTER_STORAGE, economy.energy_income * STORAGE_SECONDS)
	if economy.energy_capacity < store_wanted and count_of(census, "energy_storage") < ENERGY_STORES_MAX then
		if can_build(builder, "energy_storage") and in_progress(census, "energy_storage") == 0 then
			return cluster_site(brain, census, "energy_storage")
		end
		return nil
	end
	if economy.metal_overflowing then
		return nil
	end
	local def_name = if economy.energy_income >= ADVANCED_CONVERTER_ENERGY
			and can_build(builder, "advanced_energy_converter")
		then "advanced_energy_converter"
		else "energy_converter"
	local building = 0
	for _, converter in CONVERTER_DEFS do
		building += in_progress(census, converter)
	end
	if can_build(builder, def_name) and building < CONVERTERS_AT_ONCE then
		return cluster_site(brain, census, def_name)
	end
	return nil
end

-- A construction turret beside its labs, now and then as its income grows (see TURRET_INCOME).
local function turret_task(brain: Brain, census: Census, economy: Economy, builder: Entity): Task?
	local income = economy.metal_income + economy.converted_metal
	if #census.factories == 0 or income < TURRET_INCOME or economy.metal_short or economy.energy_stalling then
		return nil
	end
	local turrets = count_of(census, "construction_turret") + count_of(census, "advanced_construction_turret")
	local wanted = math.min(TURRETS_MAX, math.floor(income / METAL_PER_TURRET))
	if economy.metal_overflowing then
		wanted += 1
	end
	if
		turrets >= wanted
		or in_progress(census, "construction_turret") + in_progress(census, "advanced_construction_turret") > 0
	then
		return nil
	end
	local def_name = if income >= ADVANCED_TURRET_INCOME and can_build(builder, "advanced_construction_turret")
		then "advanced_construction_turret"
		else "construction_turret"
	if can_build(builder, def_name) == false then
		return nil
	end
	return cluster_site(brain, census, def_name)
end

-- A lab of `def_name`, near home with its doorway toward the middle of the map.
local function lab_task(brain: Brain, census: Census, builder: Entity, def_name: string): Task?
	if can_build(builder, def_name) == false or count_of(census, def_name) > 0 then
		return nil
	end
	local facing = geometry.snap_facing(math.atan2(brain.forward.X, brain.forward.Z))
	return ring_site(brain, census, def_name, brain.home + brain.forward * LAB_OFFSET, 0, LAB_SEARCH_RADIUS, facing)
end

-- Bots, unless a vehicle could not get from home toward the middle of the map, which is when the ground is too rough
-- for them; otherwise either, by a toss.
local function choose_line(brain: Brain): Line
	local probe = unit_defs.get "construction_vehicle"
	local toward = brain.home + brain.forward * 120
	if heightmap.in_bounds(toward.X, toward.Z) == false then
		toward = brain.home + brain.forward * 40
	end
	local from = unit_defs.surface_position(probe, brain.home.X, brain.home.Z)
	local to = unit_defs.surface_position(probe, toward.X, toward.Z)
	if pathfinder.has_straight_path(probe, from, to) == false then
		return "bot"
	end
	return if brain.rng:NextNumber() < 0.5 then "bot" else "vehicle"
end

-- Something for `builder` to build, the first that is wanted of what it can build (see the top of this file).
local function choose_task(brain: Brain, census: Census, economy: Economy, builder: Entity): Task?
	local line = brain.line
	local builders = #census.builders
	local commander = is_commander(builder)
	-- the commander keeps to the base
	local reach: number? = if commander then BASE_RADIUS else nil
	local tasks: { () -> Task? } = {
		function(): Task?
			return if line ~= nil then lab_task(brain, census, builder, LABS[line]) else nil
		end,
		function(): Task?
			if economy.energy_stalling and energy_in_progress(census) < builders then
				return energy_task(brain, census, economy, builder)
			end
			return nil
		end,
		function(): Task?
			if line ~= nil and economy.metal_income >= T2_METAL_INCOME and #census.factories > 0 then
				return lab_task(brain, census, builder, ADVANCED_LABS[line])
			end
			return nil
		end,
		function(): Task?
			return turret_task(brain, census, economy, builder)
		end,
		function(): Task?
			if in_progress(census, "metal_extractor") < math.max(1, math.ceil(builders / 2)) then
				return extractor_task(brain, census, builder, reach)
			end
			return nil
		end,
		function(): Task?
			local wanted = energy_wanted(census, economy)
			if economy.energy_income < wanted and energy_in_progress(census) < math.max(1, math.ceil(builders / 3)) then
				return energy_task(brain, census, economy, builder)
			end
			return nil
		end,
		function(): Task?
			return conversion_task(brain, census, economy, builder)
		end,
		function(): Task?
			if #census.factories > 0 and in_progress(census, "guard") < 2 then
				return guard_task(brain, census, builder)
			end
			return nil
		end,
		function(): Task?
			if in_progress(census, "advanced_metal_extractor") < census.advanced_builders then
				return upgrade_task(brain, census, builder)
			end
			return nil
		end,
		function(): Task?
			local wanted = math.min(AIR_DEFENSES_MAX, math.ceil(brain.field.enemy_air_count / 2))
			local have = #census.air_defenses + in_progress(census, "thistle") + in_progress(census, "eradicator")
			if brain.field.enemy_air_count >= AIR_THREAT_COUNT and have < wanted then
				return air_defense_task(brain, census, builder, economy)
			end
			return nil
		end,
		function(): Task?
			return extractor_task(brain, census, builder, reach)
		end,
	}
	for _, choose in tasks do
		local task = choose()
		if
			task ~= nil
			and (commander == false or geometry.distance_2d(task.position, brain.home) <= BASE_RADIUS)
			and route_danger(brain, builder.position, task.position) < SAFE_DANGER
		then
			return task
		end
	end
	return nil
end

-- The way for `unit` to within `reach` of `goal`, as move orders to go before the order that takes it there, or nil if
-- it needs a route and this thought has none left to give.
local function waypoints(unit: Entity, goal: Vector3, reach: number): { Order }?
	local def = unit_defs.of(unit)
	if def.air ~= nil or geometry.distance_2d(unit.position, goal) <= reach then
		return {}
	end
	if pathfinder.has_straight_path(def, unit.position, unit_defs.surface_position(def, goal.X, goal.Z)) then
		return {}
	end
	if paths_left <= 0 then
		return nil
	end
	paths_left -= 1
	local chain: { Order } = {}
	for _, point in pathfinder.waypoints_to(def, unit.position, goal, reach, PATH_MAX_EXPANSIONS) do
		table.insert(chain, { kind = "move", position = unit_defs.surface_position(def, point.X, point.Z) })
	end
	return chain
end

-- Sends `builder` to put up `task`. Returns whether it went.
local function send_to_build(brain: Brain, census: Census, builder: Entity, task: Task): boolean
	local reach = (unit_defs.of(builder).build_range or 0) * 0.8
	local chain = waypoints(builder, task.position, reach)
	if chain == nil or (#chain > 0 and chain_danger(brain, builder, chain, task.position) >= SAFE_DANGER) then
		return false
	end
	table.insert(chain, {
		kind = "build",
		position = task.position,
		target_id = nil,
		def_name = task.def_name,
		facing = task.facing,
	})
	orders.issue(builder, chain, false, false)
	add_plan(census, task.def_name, task.position, task.facing)
	brain.assisting[builder.id] = nil
	if is_commander(builder) == false and geometry.distance_2d(task.position, brain.home) > BASE_RADIUS then
		brain.expanding[builder.id] = true
	end
	return true
end

-- With only a commander: extractors on the spots nearest home, wind turbines, and then a lab, all in one queue.
local function open(brain: Brain, census: Census, commander: Entity)
	brain.opened = true
	local chain: { Order } = {}
	local function plan(task: Task?)
		if task == nil then
			return
		end
		table.insert(chain, {
			kind = "build",
			position = task.position,
			target_id = nil,
			def_name = task.def_name,
			facing = task.facing,
		})
		add_plan(census, task.def_name, task.position, task.facing)
	end
	for _ = 1, OPENING_EXTRACTORS do
		plan(extractor_task(brain, census, commander, BASE_RADIUS))
	end
	for _ = 1, OPENING_TURBINES do
		plan(cluster_site(brain, census, "wind_turbine"))
	end
	local line = brain.line or choose_line(brain)
	brain.line = line
	plan(lab_task(brain, census, commander, LABS[line]))
	if #chain > 0 then
		orders.issue(commander, chain, false, false)
	end
end

-- Whether `builder` has nothing to do that the AI would not take it off: no orders, or help it was given for want of
-- anything better and has been at a while.
local function is_available(brain: Brain, builder: Entity): boolean
	local fled_until = brain.fleeing[builder.id]
	if fled_until ~= nil then
		if clock < fled_until then
			return false
		end
		brain.fleeing[builder.id] = nil
	end
	if #builder.orders == 0 then
		brain.assisting[builder.id] = nil
		return true
	end
	local recheck = brain.assisting[builder.id]
	return recheck ~= nil and clock >= recheck
end

-- Something for a builder with nothing better to do to help with: the dearest unfinished building of its own near it,
-- somewhere quiet, or else a lab of its own that is making something, which it guards and so helps.
local function assist(brain: Brain, census: Census, builder: Entity)
	local best: Entity? = nil
	local best_worth = 0
	for _, building in census.structures do
		if
			building.state ~= "blueprint"
			or geometry.distance_2d(building.position, builder.position) > BASE_RADIUS * 2
		then
			continue
		end
		local worth = unit_defs.power(unit_defs.of(building))
		if worth > best_worth and route_danger(brain, builder.position, building.position) < SAFE_DANGER then
			best = building
			best_worth = worth
		end
	end
	local order: Order? = nil
	if best ~= nil then
		order = { kind = "assist", position = nil, target_id = best.id }
	else
		local lab: Entity? = nil
		local nearest = math.huge
		for _, factory in census.factories do
			local distance = geometry.distance_2d(factory.position, builder.position)
			if #factory.queue > 0 and distance < nearest then
				lab = factory
				nearest = distance
			end
		end
		if lab ~= nil then
			order = { kind = "guard", position = nil, target_id = lab.id }
		end
	end
	if order == nil then
		-- nothing at all: a builder out on the map comes home
		if geometry.distance_2d(builder.position, brain.home) > BASE_RADIUS and #builder.orders == 0 then
			local chain = waypoints(builder, brain.home, BASE_RADIUS / 2)
			if chain ~= nil then
				table.insert(chain, { kind = "move", position = brain.home })
				orders.issue(builder, chain, false, false)
			end
		end
		return
	end
	local current = builder.orders[1]
	if current == nil or current.kind ~= order.kind or current.target_id ~= order.target_id then
		orders.issue(builder, { order }, false, false)
	end
	brain.assisting[builder.id] = clock + ASSIST_RECHECK
end

-- A builder out beyond the base that is caught somewhere the enemy reaches, or is being hit, drops what it was doing
-- and runs for home.
local function flee(brain: Brain, builder: Entity, hurt: boolean): boolean
	if is_commander(builder) or geometry.distance_2d(builder.position, brain.home) <= BASE_RADIUS then
		return false
	end
	if hurt == false and danger_field.at(brain.field, builder.position) < FLEE_DANGER then
		return false
	end
	local chain = waypoints(builder, brain.home, BASE_RADIUS / 2) or {}
	table.insert(chain, { kind = "move", position = brain.home })
	orders.issue(builder, chain, false, false)
	brain.fleeing[builder.id] = clock + FLEE_SECONDS
	brain.expanding[builder.id] = nil
	brain.assisting[builder.id] = nil
	return true
end

-- Where `builder`'s orders take it before it gets to work, as the moves on the way and where the work is; nil when
-- it has nothing to go to, or is guarding something, which it keeps beside.
local function errand_of(builder: Entity): ({ Order }, Vector3?)
	local moves: { Order } = {}
	for _, order in builder.orders do
		if order.kind == "move" then
			table.insert(moves, order)
			continue
		end
		if order.kind == "build" then
			return moves, order.position
		end
		if order.kind == "assist" or order.kind == "repair" or order.kind == "reclaim" then
			local target = if order.target_id ~= nil then state.get(order.target_id) else nil
			return moves, if target ~= nil then target.position else order.position
		end
		return moves, nil
	end
	local last = moves[#moves]
	return moves, if last ~= nil then last.position else nil
end

-- Whether what `builder` is on its way to do has turned dangerous, where the work is or on the way there.
local function errand_dangerous(brain: Brain, builder: Entity): boolean
	local moves, goal = errand_of(builder)
	if goal == nil then
		return false
	end
	-- the moves already behind it are dropped from its orders, so this is only the way it has left to go
	return danger_field.at(brain.field, goal) >= ABORT_DANGER
		or chain_danger(brain, builder, moves, goal) >= ABORT_DANGER
end

local function run_builders(brain: Brain, census: Census, economy: Economy)
	for _, builder in census.builders do
		local last_health = brain.health[builder.id]
		local hurt = last_health ~= nil and builder.health < last_health
		if is_commander(builder) == false then
			brain.health[builder.id] = builder.health
		end
		if brain.fleeing[builder.id] == nil then
			if flee(brain, builder, hurt) then
				continue
			end
			-- the commander, which can fight, sees its errands through; it is only never sent on a dangerous one
			if is_commander(builder) == false and #builder.orders > 0 and errand_dangerous(brain, builder) then
				-- out on the map it goes home; in the base it only stops, and is given something else below
				if flee(brain, builder, true) == false then
					orders.issue(builder, {}, false, false)
					brain.assisting[builder.id] = nil
				end
			end
		end
		if is_available(brain, builder) == false then
			continue
		end
		brain.expanding[builder.id] = nil
		local task = choose_task(brain, census, economy, builder)
		if task ~= nil and send_to_build(brain, census, builder, task) then
			continue
		end
		assist(brain, census, builder)
	end
end

-- What a lab should make next.
local function fighter_for(brain: Brain, economy: Economy, options: { string }): string?
	if #options == 0 then
		return nil
	end
	local cheapest = math.huge
	for _, name in options do
		cheapest = math.min(cheapest, unit_defs.get(name).metal_cost)
	end
	local limit = math.max((economy.metal_income + economy.converted_metal) * AFFORD_SECONDS, cheapest)
	local dearest = 0
	for _, name in options do
		local cost = unit_defs.get(name).metal_cost
		if cost <= limit then
			dearest = math.max(dearest, cost)
		end
	end
	local chosen: { string } = {}
	for _, name in options do
		local cost = unit_defs.get(name).metal_cost
		if cost <= limit and cost >= dearest * FODDER_SHARE then
			table.insert(chosen, name)
		end
	end
	if #chosen == 0 then
		return nil
	end
	return chosen[brain.rng:NextInteger(1, #chosen)]
end

local function product_for(brain: Brain, census: Census, economy: Economy, factory: Entity): string?
	local constructors: { string } = {}
	local rezbots: { string } = {}
	local anti_air: { string } = {}
	local fighters: { string } = {}
	local options: { string } = unit_defs.of(factory).build_options or {}
	for _, name in options do
		local def = unit_defs.get(name)
		if def.kind ~= "unit" or def.drone == true or campaign.can_build(brain.team, name) == false then
			continue
		end
		local role = role_of(name)
		if role.builder then
			table.insert(constructors, name)
		elseif role.rezbot then
			table.insert(rezbots, name)
		elseif role.hits_ground or role.hits_air then
			if role.anti_air then
				table.insert(anti_air, name)
			end
			if role.hits_ground then
				table.insert(fighters, name)
			end
		end
	end

	local income = economy.metal_income + economy.converted_metal
	for _, name in constructors do
		local wanted = if role_of(name).advanced
			then math.clamp(1 + math.floor(income / METAL_PER_ADVANCED_CONSTRUCTOR), 1, ADVANCED_CONSTRUCTORS_MAX)
			else math.clamp(
				CONSTRUCTORS_MIN + math.floor(income / METAL_PER_CONSTRUCTOR),
				CONSTRUCTORS_MIN,
				CONSTRUCTORS_MAX
			)
		if (census.counts[name] or 0) < wanted then
			return name
		end
	end
	-- short of metal, it makes nothing more than builders until it comes in
	if economy.metal_short then
		return nil
	end

	local safe_wrecks = 0
	for _, wreck in census.wrecks do
		if danger_field.at(brain.field, wreck.position) < SAFE_DANGER then
			safe_wrecks += 1
		end
	end
	for _, name in rezbots do
		local wanted = if safe_wrecks > 0
			then math.min(REZBOTS_MAX, 1 + math.floor(safe_wrecks / WRECKS_PER_REZBOT))
			else 0
		if (census.counts[name] or 0) < wanted then
			return name
		end
	end

	local aircraft = brain.field.enemy_air_count
	if
		aircraft >= AIR_THREAT_COUNT
		and #anti_air > 0
		and census.anti_air_units < math.ceil(aircraft * ANTI_AIR_PER_AIRCRAFT)
	then
		return anti_air[brain.rng:NextInteger(1, #anti_air)]
	end
	return fighter_for(brain, economy, fighters)
end

local function run_factories(brain: Brain, census: Census, economy: Economy)
	for _, factory in census.factories do
		if #factory.queue >= FACTORY_QUEUE then
			continue
		end
		local product = product_for(brain, census, economy, factory)
		if product ~= nil and production.enqueue(factory, product) then
			bump(census.counts, product)
		end
	end
end

-- Rezbots raise the wrecks of units that lie somewhere quiet, by a quiet way, reclaim any other wreck there, and with no wrecks about
-- reclaim the rocks and trees near home.
local function run_rezbots(brain: Brain, census: Census)
	local claimed: { [EntityId]: boolean } = {}
	for rezbot_id, target_id in brain.salvaging do
		local rezbot = state.get(rezbot_id)
		if rezbot == nil or #rezbot.orders == 0 or state.get(target_id) == nil then
			brain.salvaging[rezbot_id] = nil
		else
			claimed[target_id] = true
		end
	end
	for _, rezbot in census.rezbots do
		if brain.salvaging[rezbot.id] ~= nil then
			continue
		end
		if #rezbot.orders > 0 and brain.assisting[rezbot.id] == nil then
			continue
		end
		local best: Entity? = nil
		local best_distance = math.huge
		for _, wreck in census.wrecks do
			if claimed[wreck.id] then
				continue
			end
			if danger_field.peak_near(brain.field, wreck.position, danger_field.CELL_STUDS) >= SAFE_DANGER then
				continue
			end
			local distance = geometry.distance_2d(rezbot.position, wreck.position)
			if distance < best_distance and route_danger(brain, rezbot.position, wreck.position) < SAFE_DANGER then
				best = wreck
				best_distance = distance
			end
		end
		if best == nil then
			for _, rock in census.reclaimables do
				if claimed[rock.id] or geometry.distance_2d(rock.position, brain.home) > BASE_RADIUS * 2 then
					continue
				end
				local distance = geometry.distance_2d(rezbot.position, rock.position)
				if distance < best_distance then
					best = rock
					best_distance = distance
				end
			end
		end
		if best == nil then
			assist(brain, census, rezbot)
			continue
		end
		local kind: OrderKind = if best.kind == "wreck" and resurrection.can_resurrect(rezbot, best)
			then "resurrect"
			else "reclaim"
		if kind == "reclaim" and reclaim.can_reclaim(rezbot, best) == false then
			continue
		end
		local chain = waypoints(rezbot, best.position, (unit_defs.of(rezbot).build_range or 0) * 0.8)
		if chain == nil then
			continue
		end
		table.insert(chain, { kind = kind, position = best.position, target_id = best.id })
		orders.issue(rezbot, chain, false, false)
		brain.salvaging[rezbot.id] = best.id
		brain.assisting[rezbot.id] = nil
		claimed[best.id] = true
	end
end

local function is_escort(brain: Brain, unit: Entity): boolean
	return brain.escorts[unit.id] ~= nil
end

-- Every builder out beyond the base gets ESCORTS_PER_BUILDER of the army waiting at home to guard it, and lets them go
-- once it is back or done.
local function run_escorts(brain: Brain, census: Census)
	local guarding: { [EntityId]: number } = {}
	for escort_id, builder_id in brain.escorts do
		local escort = state.get(escort_id)
		local builder = state.get(builder_id)
		if escort == nil then
			brain.escorts[escort_id] = nil
			continue
		end
		if builder == nil or brain.expanding[builder_id] ~= true then
			brain.escorts[escort_id] = nil
			brain.goals[escort_id] = nil
			escort.orders = {}
			continue
		end
		guarding[builder_id] = (guarding[builder_id] or 0) + 1
	end
	-- only what is waiting at home is taken; an army on its way somewhere keeps going
	if brain.mode ~= "gather" then
		return
	end
	for builder_id in brain.expanding do
		local builder = state.get(builder_id)
		if builder == nil then
			brain.expanding[builder_id] = nil
			continue
		end
		local have = guarding[builder_id] or 0
		while have < ESCORTS_PER_BUILDER do
			local best: Entity? = nil
			local best_distance = math.huge
			for _, unit in census.army do
				if is_escort(brain, unit) or unit_defs.of(unit).air ~= nil then
					continue
				end
				local distance = geometry.distance_2d(unit.position, builder.position)
				if distance < best_distance then
					best = unit
					best_distance = distance
				end
			end
			if best == nil then
				break
			end
			orders.issue(best, { { kind = "guard", position = nil, target_id = builder.id } }, false, false)
			brain.escorts[best.id] = builder.id
			brain.goals[best.id] = nil
			have += 1
		end
	end
end

local function worth_of(units: { Entity }): number
	local total = 0
	for _, unit in units do
		total += unit_defs.power(unit_defs.of(unit))
	end
	return total
end

local function centroid(units: { Entity }): Vector3
	local sum = Vector3.zero
	for _, unit in units do
		sum += unit.position
	end
	return sum / math.max(1, #units)
end

-- The nearest enemy that can fight and has come close to home, or to one of its extractors.
local function nearest_raider(brain: Brain, census: Census): Entity?
	local best: Entity? = nil
	local best_distance = math.huge
	for _, enemy in census.enemy_units do
		local role = role_of(enemy.def_name)
		if role.hits_ground == false then
			continue
		end
		local distance = geometry.distance_2d(enemy.position, brain.home)
		local near = distance <= DEFEND_RADIUS
		if near == false then
			for _, extractor in census.extractors do
				if geometry.distance_2d(enemy.position, extractor.position) <= ALERT_RADIUS then
					near = true
					break
				end
			end
		end
		if near and distance < best_distance then
			best = enemy
			best_distance = distance
		end
	end
	return best
end

-- What to attack: the enemy's building nearest `from` that stands where the danger is well under `worth`, or with none,
-- a unit of theirs that does.
local function choose_target(brain: Brain, census: Census, from: Vector3, worth: number): Entity?
	local best: Entity? = nil
	local best_score = math.huge
	local function consider(target: Entity)
		local danger = danger_field.peak_near(brain.field, target.position, TARGET_DANGER_RADIUS)
		if danger * ATTACK_SUPERIORITY > worth then
			return
		end
		local score = geometry.distance_2d(from, target.position) * (1 + danger / math.max(worth, 1))
		if score < best_score then
			best = target
			best_score = score
		end
	end
	for _, target in census.enemy_structures do
		if target.def_name ~= "wall" then
			consider(target)
		end
	end
	if best == nil then
		for _, target in census.enemy_units do
			if unit_defs.of(target).air == nil then
				consider(target)
			end
		end
	end
	return best
end

-- Sends `unit` to `goal`, fighting its way there or only moving, by a route if it needs one. Returns whether it went:
-- it waits for the next thought when there are no routes left to give in this one.
local function send(brain: Brain, unit: Entity, goal: Vector3, kind: OrderKind): boolean
	local def = unit_defs.of(unit)
	local at = unit_defs.surface_position(def, goal.X, goal.Z)
	local chain: { Order } = {}
	if def.air == nil and pathfinder.has_straight_path(def, unit.position, at) == false then
		if paths_left <= 0 then
			return false
		end
		paths_left -= 1
		local path = pathfinder.find_path(def, unit.position, at, PATH_MAX_EXPANSIONS)
		for _, step in path.orders do
			table.insert(chain, { kind = kind, position = step.position })
		end
	end
	if #chain == 0 then
		table.insert(chain, { kind = kind, position = at })
	end
	orders.issue(unit, chain, false, false)
	brain.goals[unit.id] = goal
	return true
end

-- Sends every unit of `army` that is not already on its way to `goal` there.
local function send_all(brain: Brain, army: { Entity }, goal: Vector3, kind: OrderKind, slack: number)
	for _, unit in army do
		local sent = brain.goals[unit.id]
		local settled = geometry.distance_2d(unit.position, goal) <= slack
		if kind == "move" and settled then
			continue
		end
		if sent ~= nil and #unit.orders > 0 and geometry.distance_2d(sent, goal) <= GOAL_DRIFT then
			continue
		end
		send(brain, unit, goal, kind)
	end
end

local function rally_point(brain: Brain): Vector3
	local point = brain.home + brain.forward * RALLY_OFFSET
	if heightmap.in_bounds(point.X, point.Z) == false then
		point = brain.home
	end
	return heightmap.ground_position(point.X, point.Z)
end

local function run_army(brain: Brain, census: Census, economy: Economy)
	local army: { Entity } = {}
	for _, unit in census.army do
		if is_escort(brain, unit) == false then
			table.insert(army, unit)
		end
	end
	if #army == 0 then
		brain.mode = "gather"
		return
	end
	local worth = worth_of(army)

	local raider = nearest_raider(brain, census)
	if raider ~= nil then
		brain.mode = "defend"
		brain.target = raider.id
		send_all(brain, army, raider.position, "fight", 0)
		return
	end
	if brain.mode == "defend" then
		brain.mode = "gather"
		brain.target = nil
	end

	if brain.mode == "attack" then
		local middle = centroid(army)
		if danger_field.at(brain.field, middle) > worth * RETREAT_RATIO then
			brain.mode = "gather"
			brain.target = nil
			brain.next_attack_at = clock + REGROUP_SECONDS
			for _, unit in army do
				brain.goals[unit.id] = nil
			end
		else
			local target = if brain.target ~= nil then state.get(brain.target) else nil
			if target == nil or target.team == brain.team then
				target = choose_target(brain, census, middle, worth)
				brain.target = if target ~= nil then target.id else nil
			end
			if target ~= nil then
				send_all(brain, army, target.position, "fight", 0)
				return
			end
			brain.mode = "gather"
		end
	end

	-- gathering: waiting at the rally point until it is worth enough to go
	send_all(brain, army, rally_point(brain), "move", RALLY_SLACK)
	if clock >= brain.next_attack_at and worth >= ATTACK_BASE + economy.metal_income * ATTACK_SECONDS then
		local target = choose_target(brain, census, centroid(army), worth)
		if target ~= nil then
			brain.mode = "attack"
			brain.target = target.id
			for _, unit in army do
				brain.goals[unit.id] = nil
			end
		end
	end
end

-- Forgets what it remembered about anything that is gone.
local function prune(brain: Brain)
	for _, tally in { brain.assisting, brain.fleeing, brain.goals, brain.expanding } :: { { [EntityId]: any } } do
		for id in tally do
			if state.get(id) == nil then
				tally[id] = nil
			end
		end
	end
	for id in brain.full do
		if state.get(id) == nil then
			brain.full[id] = nil
		end
	end
	-- a builder it was keeping an eye on that is gone was lost (the commander is never looked at here)
	for id in brain.health do
		local builder = state.get(id)
		if builder == nil or builder.alive == false then
			brain.health[id] = nil
			brain.builders_lost += 1
		end
	end
end

local function think(brain: Brain)
	brain.next_think = clock + THINK_INTERVAL
	local team = state.get_team(brain.team)
	if team == nil then
		return
	end
	if clock >= brain.next_field or danger_field.fits_map(brain.field) == false then
		if danger_field.fits_map(brain.field) == false then
			brain.field = danger_field.new(brain.team)
		end
		danger_field.refresh(brain.field)
		brain.next_field = clock + FIELD_INTERVAL
	end
	prune(brain)
	paths_left = PATHS_PER_THINK

	local census = take_census(brain)
	local economy = read_economy(team, census)

	local commander = census.commander
	if brain.opened == false then
		if commander ~= nil and #census.factories == 0 and #census.builders == 1 and #census.structures == 0 then
			if #commander.orders == 0 then
				open(brain, census, commander)
			end
			return
		end
		brain.opened = true
	end
	if brain.line == nil then
		for line, lab in LABS do
			if count_of(census, lab) > 0 then
				brain.line = line
			end
		end
		if brain.line == nil then
			brain.line = choose_line(brain)
		end
	end

	run_factories(brain, census, economy)
	run_builders(brain, census, economy)
	run_rezbots(brain, census)
	run_escorts(brain, census)
	run_army(brain, census, economy)
end

local function new_brain(team_id: TeamId, home: Vector3): Brain
	local forward = geometry.flatten(-home)
	return {
		team = team_id,
		home = home,
		forward = if forward.Magnitude > 1 then forward.Unit else Vector3.new(1, 0, 0),
		line = nil,
		field = danger_field.new(team_id),
		rng = Random.new(team_id * 7919 + 17),
		next_think = clock + (team_id % 7) / 7 * THINK_INTERVAL,
		next_field = clock,
		opened = false,
		assisting = {},
		expanding = {},
		fleeing = {},
		health = {},
		builders_lost = 0,
		escorts = {},
		salvaging = {},
		goals = {},
		mode = "gather",
		target = nil,
		next_attack_at = clock,
		full = {},
	}
end

-- Where the team's commander stands, or its start if it has none.
local function home_of(team_id: TeamId): Vector3
	for _, entity in state.all() do
		if entity.alive and entity.team == team_id and is_commander(entity) then
			return entity.position
		end
	end
	return heightmap.ground_position(starts.center(team_id).X, starts.center(team_id).Y)
end

-- Hands team `team_id`, which should already have its commander, to the AI.
local function add(team_id: TeamId)
	state.flush()
	brains[team_id] = new_brain(team_id, home_of(team_id))
end

-- Makes team `team_id`'s AI build from `line`'s labs, whatever it would have chosen.
local function set_line(team_id: TeamId, line: Line)
	local brain = brains[team_id]
	if brain ~= nil then
		brain.line = line
	end
end

local function remove(team_id: TeamId)
	brains[team_id] = nil
end

local function is_ai(team_id: TeamId): boolean
	return brains[team_id] ~= nil
end

-- The start that is furthest from everything anyone has on the map: the usual start of one of the map's boxes.
local function free_start(): Vector2
	local best = Vector2.zero
	local best_distance = -1
	for index = 1, starts.box_count() do
		local spot = starts.default_spot(index)
		local at = Vector3.new(spot.X, 0, spot.Y)
		local nearest = math.huge
		for _, other in state.all() do
			if other.alive and other.team ~= 0 and other.kind ~= "wreck" and other.kind ~= "reclaimable" then
				nearest = math.min(nearest, geometry.distance_2d(at, other.position))
			end
		end
		if nearest > best_distance then
			best = spot
			best_distance = nearest
		end
	end
	return best
end

-- Makes a new team for the AI, named `name`, and puts its commander down at the start furthest from everyone. Returns
-- its team, or nil if there was no room for the commander.
local function spawn_opponent(name: string?): TeamId?
	local count = 0
	for _ in brains do
		count += 1
	end
	local team_id = players.create_team(name or `AI {count + 1}`)
	spawning.set_start(team_id, free_start())
	if spawning.give_starting_force(team_id) == false then
		return nil
	end
	add(team_id)
	return team_id
end

-- A new map: every team the AI plays starts over, at the start furthest from everyone, as a player does. Called once
-- the map is built and the players' commanders stand.
local function restart_on_new_map()
	local teams: { TeamId } = {}
	for team_id in brains do
		table.insert(teams, team_id)
	end
	table.sort(teams)
	for _, team_id in teams do
		spawning.set_start(team_id, free_start())
		spawning.give_starting_force(team_id)
		add(team_id)
	end
end

-- `opponents` teams are put down for the AI on the first step of the game.
local function init(opponents: number)
	opponents_wanted = math.max(0, math.floor(opponents))
end

-- Called once per step, after income and before orders, so what the AI decides is what its units do this step.
local function tick(delta: number)
	clock += delta
	if opponents_placed == false then
		opponents_placed = true
		for _ = 1, opponents_wanted do
			spawn_opponent(nil)
		end
	end
	for _, brain in brains do
		if clock >= brain.next_think then
			think(brain)
		end
	end
end

-- A line about how team `team_id`'s AI is getting on, for a command to print.
local function describe(team_id: TeamId): string?
	local brain = brains[team_id]
	local team = state.get_team(team_id)
	if brain == nil or team == nil then
		return nil
	end
	local census = take_census(brain)
	return `{team.name} ({team_id}): {brain.line or "no line"}, army {brain.mode} with {#census.army} worth {math.floor(
		worth_of(census.army)
	)}, {#census.builders} builders ({brain.builders_lost} lost), {#census.factories} labs, {#census.extractors} extractors, metal {string.format(
		"%.1f",
		team.metal_income
	)}/s, energy {string.format("%.0f", team.energy_income)}/s, {brain.field.enemy_air_count} enemy aircraft`
end

local function teams(): { TeamId }
	local list: { TeamId } = {}
	for team_id in brains do
		table.insert(list, team_id)
	end
	table.sort(list)
	return list
end

return table.freeze({
	init = init,
	tick = tick,
	add = add,
	remove = remove,
	set_line = set_line,
	is_ai = is_ai,
	teams = teams,
	spawn_opponent = spawn_opponent,
	restart_on_new_map = restart_on_new_map,
	describe = describe,
})
