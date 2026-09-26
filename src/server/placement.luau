-- Answers "can this footprint go here" on the server (the rules are shared/placement_rules): the check a
-- construction_bot runs before dropping a blueprint, and a factory on the spot in front of itself before starting the
-- next unit.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local placement_rules = require(ReplicatedStorage.Shared.placement_rules)

local state = require(script.Parent.state)
local air = require(script.Parent.air)
local spatial = require(script.Parent.spatial)

type Entity = types.Entity
type TeamId = types.TeamId
type Occupants = placement_rules.Occupants<Entity>

local function half_extents_for(entity: Entity): Vector2
	return placement_rules.footprint(entity.def, entity.facing)
end

-- Whether something in the way of a footprint can be moved off it for `team` (`placement_rules.clearable`).
local function clearable(other: Entity, team: TeamId): boolean
	return placement_rules.clearable(other.kind, other.state, other.def, other.team == team)
end

-- The map as the placement rules see it, for a builder of `clearing_team`, which clears what it can off a footprint
-- (`clearable`), or for nothing that clears anything. One of each is made, the first time it is asked for.
local function kind_of(entity: Entity): types.EntityKind
	return entity.kind
end
local function position_of(entity: Entity): Vector3
	return entity.position
end
local function facing_of(entity: Entity): number
	return entity.facing
end
-- the dead are not in the way, though they are in `spatial` until the step ends; what has just been made is, though it
-- is not in `spatial` until it joins the world (`state.pending`), so that the next thing put down beside it sees it
local function each_living_near(x: number, z: number, radius: number, visit: (Entity) -> ())
	spatial.each_near(x, z, radius, function(other: Entity)
		if other.alive then
			visit(other)
		end
	end)
	for _, made in state.pending() do
		if made.alive and state.carrier_of(made.id) == nil then
			visit(made)
		end
	end
end
local function def_of(entity: Entity): types.EntityDef
	return entity.def
end
local function view(clearing: (Entity) -> boolean): Occupants
	local occupants: Occupants = {
		each_near = each_living_near,
		kind = kind_of,
		def = def_of,
		position = position_of,
		facing = facing_of,
		airborne = air.is_airborne,
		clearable = clearing,
	}
	return table.freeze(occupants)
end
local CLEARING_NOTHING = view(function(_: Entity): boolean
	return false
end)
local views: { [TeamId]: Occupants } = {}
local function occupants_for(clearing_team: TeamId?): Occupants
	if clearing_team == nil then
		return CLEARING_NOTHING
	end
	local found = views[clearing_team]
	if found == nil then
		found = view(function(other: Entity): boolean
			return clearable(other, clearing_team)
		end)
		views[clearing_team] = found
	end
	return found
end

-- Everything standing in the way of a footprint at `position`, `ignore` aside, clearable or not.
local function overlapping(def_name: string, position: Vector3, facing: number, ignore: Entity?): { Entity }
	local found: { Entity } = {}
	placement_rules.each_in_the_way(CLEARING_NOTHING, unit_defs.get(def_name), position, facing, function(other: Entity)
		if other ~= ignore then
			table.insert(found, other)
		end
	end)
	return found
end

-- Returns whether the footprint is clear, and what is wrong when it is not (`placement_rules.problem`). Given a
-- `clearing_team`, what that team can clear away, wrecks and its own movable units, is not counted as being in the way:
-- removing it is the job of the builder, once it gets there. `ignore`, the builder itself, is never in the way.
local function can_place(
	def_name: string,
	position: Vector3,
	facing: number,
	ignore: Entity?,
	clearing_team: TeamId?
): (boolean, placement_rules.Problem?)
	local wrong = placement_rules.problem(occupants_for(clearing_team), def_name, position, facing, ignore)
	return wrong == nil, wrong
end

-- The middle of something of `def_name` standing at (x, z) (`placement_rules.ground_center`).
local function ground_center(def_name: string, x: number, z: number): Vector3
	return placement_rules.ground_center(unit_defs.get(def_name), x, z)
end

-- Where `builder` already has something spot-bound queued to be built: none without a builder.
local function queued_spots(builder: Entity?): { Vector3 }
	local found: { Vector3 } = {}
	if builder == nil then
		return found
	end
	for _, order in builder.orders do
		local def_name = order.def_name
		if
			order.kind == "build"
			and def_name ~= nil
			and order.position ~= nil
			and unit_defs.get(def_name).spot ~= nil
		then
			table.insert(found, order.position)
		end
	end
	return found
end

-- Where a building asked for at (x, z) would actually go, turned to `facing` (`placement_rules.resolve_center`): a spot
-- `builder` has a build queued onto is spoken for.
local function resolve_center(def_name: string, x: number, z: number, facing: number, builder: Entity?): Vector3?
	return placement_rules.resolve_center(
		CLEARING_NOTHING,
		unit_defs.get(def_name),
		x,
		z,
		facing,
		queued_spots(builder)
	)
end

-- The first place on the rings round `around`, each `spacing` further out and six more places round than the one
-- inside it, out to ring `rings`, where something of `def_name` turned to `facing` can go: where `resolve_center` puts
-- it, clear (`can_place`), and, given `fits`, somewhere that allows. Nil when there is none.
local function find_free_spot(
	def_name: string,
	around: Vector3,
	facing: number,
	rings: number,
	spacing: number,
	fits: ((center: Vector3) -> boolean)?
): Vector3?
	for ring = 0, rings do
		local count = math.max(1, ring * 6)
		for index = 0, count - 1 do
			local angle = index * (math.pi * 2 / count)
			local center = resolve_center(
				def_name,
				around.X + math.cos(angle) * ring * spacing,
				around.Z + math.sin(angle) * ring * spacing,
				facing
			)
			if center ~= nil and (fits == nil or fits(center)) and can_place(def_name, center, facing, nil) then
				return center
			end
		end
	end
	return nil
end

-- A search for somewhere on rings round `around`, from `inner` out to `outer`, `step` apart, with points about `step`
-- apart round each (six at the least, and one at the very middle), each ring starting at an angle rolled from `random`:
-- `try(x, z, angle)` is asked of each point in turn that `within` lets through (every point, without it), no more than
-- `max_tries` of them (all, without it), and the first thing it gives is the answer. What the game's own players look
-- for a place with: where the AI puts a building up, and where the scavengers put down what their beacons make.
local function ring_search<T>(
	around: Vector3,
	inner: number,
	outer: number,
	step: number,
	random: Random,
	try: (x: number, z: number, angle: number) -> T?,
	within: ((x: number, z: number) -> boolean)?,
	max_tries: number?
): T?
	local tries = 0
	for radius = inner, outer, step do
		local count = if radius <= 0 then 1 else math.max(6, math.floor(math.pi * 2 * radius / step))
		local first_angle = random:NextNumber(0, math.pi * 2)
		for index = 0, count - 1 do
			local angle = first_angle + index * (math.pi * 2 / count)
			local x = around.X + math.cos(angle) * radius
			local z = around.Z + math.sin(angle) * radius
			if within ~= nil and within(x, z) == false then
				continue
			end
			tries += 1
			if max_tries ~= nil and tries > max_tries then
				return nil
			end
			local found = try(x, z, angle)
			if found ~= nil then
				return found
			end
		end
	end
	return nil
end

return table.freeze({
	can_place = can_place,
	find_free_spot = find_free_spot,
	ring_search = ring_search,
	overlapping = overlapping,
	clearable = clearable,
	ground_center = ground_center,
	resolve_center = resolve_center,
	half_extents_for = half_extents_for,
})
