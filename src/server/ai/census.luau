--!strict
-- A brain's look over its team, and everything round it, at the start of a thought (`take`): what it has, what it has
-- sent its builders to put up, what each of its builders is let do (`Duty`), what it knows of the enemy, and how its
-- economy stands (`read_economy`).
--
-- What it knows of the enemy is its profile's `sees`: everything the enemy has, or, with "team_sight", only what stands
-- within SIGHT_RADIUS of something of its own side's. The danger field (danger_field.luau) is worked out from the same.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local teams = require(ReplicatedStorage.Shared.teams)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

local state = require(ServerScriptService.Server.state)
local alliances = require(ServerScriptService.Server.alliances)
local spatial = require(ServerScriptService.Server.spatial)

local catalog = require(script.Parent.catalog)
local brains = require(script.Parent.brains)

type Entity = types.Entity
type EntityId = types.EntityId
type Team = types.Team
type Brain = brains.Brain
type Profile = ai_profiles.Profile

-- A building one of its builders has been sent to put up and has not started yet.
export type Plan = {
	def_name: string,
	position: Vector3,
	facing: number,
	half: Vector2,
}

-- The strip in front of a lab's doorway that its units drive out through, which nothing is built on.
export type Lane = {
	center: Vector3,
	half: Vector2,
}

-- What one of its builders is let do: how far from home it takes an extractor (nil for anywhere); whether it goes out
-- beyond the base, where it wants an escort, runs from danger and drops an errand that turns dangerous, or keeps to the
-- base and sees its errands through, as the commander, which can fight, does; and whether it helps a lab while the
-- team is short of constructors (the profile's commander_assist_constructors).
export type Duty = {
	reach: number?,
	ventures: boolean,
	helps_lab: boolean,
}

-- How the team's economy stands.
export type Economy = {
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
export type Census = {
	commander: Entity?,
	-- units that build, the commander among them, and what each is let do
	builders: { Entity },
	duties: { [EntityId]: Duty },
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
	-- the metal spots another team's extractor stands on, finished or not, and those another team's builder is on its
	-- way to put one on (with where that builder is)
	foreign_spots: { Vector3 },
	foreign_claims: { { position: Vector3, from: Vector3 } },
	wrecks: { Entity },
	reclaimables: { Entity },
	-- what it knows of the enemy: everything, and of that its buildings worth attacking (walls and the like are not)
	-- and its units
	enemies: { Entity },
	enemy_structures: { Entity },
	enemy_units: { Entity },
}

-- How long the strip in front of a lab's doorway is.
local LANE_LENGTH = 18
-- With the profile's "team_sight", what of the enemy stands this near something of its own side's is known to it: as
-- far as a scavenger notices a player's things. The game has no sight ranges of its own.
local SIGHT_RADIUS = 220

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

-- What `builder` is let do.
local function duty_of(census: Census, builder: Entity): Duty
	return census.duties[builder.id]
end

-- Where each of `built` stands, and where its builders have been sent to put up anything whose def `planned` says of.
local function sites_of(census: Census, built: { Entity }, planned: (def_name: string) -> boolean): { Vector3 }
	local sites: { Vector3 } = {}
	for _, entity in built do
		table.insert(sites, entity.position)
	end
	for _, plan in census.plans do
		if planned(plan.def_name) then
			table.insert(sites, plan.position)
		end
	end
	return sites
end

-- How far the nearest of `sites` is from `at`; math.huge for none.
local function nearest_distance(sites: { Vector3 }, at: Vector3): number
	local nearest = math.huge
	for _, site in sites do
		nearest = math.min(nearest, geometry.distance_2d(site, at))
	end
	return nearest
end

-- How many of `sites` are within `radius` of `at`.
local function count_within(sites: { Vector3 }, at: Vector3, radius: number): number
	local found = 0
	for _, site in sites do
		if geometry.distance_2d(site, at) <= radius then
			found += 1
		end
	end
	return found
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
	if catalog.role_of(def_name).factory then
		table.insert(census.lanes, lane_of(def_name, position, facing))
	end
end

-- What a builder of the role `role` is let do, playing by `profile`.
local function duty_for(role: catalog.Role, profile: Profile): Duty
	if role.commander then
		return { reach = profile.base_radius, ventures = false, helps_lab = true }
	end
	return { reach = profile.expansion_radius, ventures = true, helps_lab = false }
end

-- Whether team `team`, or an ally of it, has something that stands within SIGHT_RADIUS of `enemy`.
local function in_sight(team: types.TeamId, enemy: Entity): boolean
	local seen = false
	spatial.each_present(enemy.position, SIGHT_RADIUS, function(other: Entity): boolean?
		seen = alliances.are_allied(team, other.team)
		return seen
	end)
	return seen
end

-- Looks the team, and everything round it, over.
local function take(brain: Brain): Census
	local census: Census = {
		commander = nil,
		builders = {},
		duties = {},
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
		foreign_spots = {},
		foreign_claims = {},
		wrecks = {},
		reclaimables = {},
		enemies = {},
		enemy_structures = {},
		enemy_units = {},
	}
	local sees_all = brain.profile.sees == "all"
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
		local role = catalog.role_of(entity.def_name)
		if role.extractor then
			table.insert(census.taken_spots, entity.position)
			if entity.team ~= brain.team then
				table.insert(census.foreign_spots, entity.position)
			end
		end
		if entity.team ~= brain.team then
			if role.builder and entity.team ~= teams.NEUTRAL then
				for _, order in entity.orders do
					local position = order.position
					if
						order.kind == "build"
						and position ~= nil
						and order.def_name ~= nil
						and catalog.role_of(order.def_name).extractor
					then
						table.insert(census.foreign_claims, { position = position, from = entity.position })
					end
				end
			end
			if
				entity.team ~= teams.NEUTRAL
				and entity.state == "active"
				and alliances.are_allied(brain.team, entity.team) == false
				and (sees_all or in_sight(brain.team, entity))
			then
				table.insert(census.enemies, entity)
				if entity.kind ~= "building" then
					table.insert(census.enemy_units, entity)
				elseif entity.def.objectify ~= true then
					table.insert(census.enemy_structures, entity)
				end
			end
			continue
		end
		-- something else commands it (brains.leave_alone)
		if brains.is_left_alone(entity.id) then
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
			local def_name, position, facing = order.def_name, order.position, order.facing
			if order.kind == "build" and def_name ~= nil and position ~= nil and facing ~= nil then
				add_plan(census, def_name, position, facing)
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
				if role.hits_ground then
					table.insert(census.ground_defenses, entity)
				end
				if role.anti_air then
					table.insert(census.air_defenses, entity)
				end
			end
			continue
		end

		if entity.state ~= "active" or unit_defs.is_drone(entity.def) then
			continue
		end
		if role.commander then
			census.commander = entity
		end
		if role.builder then
			table.insert(census.builders, entity)
			census.duties[entity.id] = duty_for(role, brain.profile)
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

local function read_economy(team: Team, census: Census, profile: Profile): Economy
	local converted = 0
	for _, def_name in catalog.CONVERTER_DEFS do
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
		energy_stalling = team.energy < team.energy_capacity * profile.stall_fill
			and team.energy_expense >= team.energy_revenue * profile.stall_spend_share,
		energy_overflowing = team.energy > team.energy_capacity * profile.overflow_fill
			and team.energy_revenue >= team.energy_expense,
		metal_overflowing = team.metal > team.metal_capacity * profile.overflow_fill,
		metal_short = team.metal < team.metal_capacity * profile.short_fill and team.metal_expense > team.metal_revenue,
	}
end

return table.freeze({
	LANE_LENGTH = LANE_LENGTH,
	take = take,
	read_economy = read_economy,
	in_progress = in_progress,
	count_of = count_of,
	buildings_of = buildings_of,
	duty_of = duty_of,
	sites_of = sites_of,
	nearest_distance = nearest_distance,
	count_within = count_within,
	bump = bump,
	lane_of = lane_of,
	add_plan = add_plan,
})
