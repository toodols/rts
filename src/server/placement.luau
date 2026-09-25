-- Answers "can this footprint go here": the check a construction_bot runs before dropping a blueprint,
-- and the same check a factory runs on the spot in front of itself before starting the next unit.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local spots = require(ReplicatedStorage.Shared.spots)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local air = require(script.Parent.air)

type Entity = types.Entity
type EntityId = types.EntityId

-- Footprints are allowed to touch; only real overlap is rejected.
local OVERLAP_PADDING = 0
-- How close to a spot a spot-bound building has to be to count as on it.
local SPOT_MATCH_RADIUS = 0.5
-- How far off its grid position a building may be, only there to forgive float error.
local GRID_TOLERANCE = 0.01
-- How close something has to be to a spot to be sitting on it or headed for it.
local TAKEN_RADIUS = 1

local function half_extents_for(entity: Entity): Vector2
	local def = unit_defs.of(entity)
	return geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), entity.facing)
end

-- Whether something in the way of a footprint can be moved off it for `team`: a wreck or a reclaimable, which is
-- reclaimed, or one of its own units that can move, which is sent away.
local function clearable(other: Entity, team: types.TeamId): boolean
	if other.kind == "wreck" or other.kind == "reclaimable" then
		return true
	end
	return other.kind == "unit"
		and other.state == "active"
		and other.team == team
		and unit_defs.of(other).max_speed ~= nil
end

-- Whether `other` is what `def_name` is built over in place (`EntityDef.upgrades`), a T1 mex under a T2 one or a
-- geothermal plant under an advanced one: it does not block the footprint, the way a wreck or a movable unit does not.
local function is_upgrade_target(def_name: string, other: Entity): boolean
	return other.kind == "building" and spots.upgrades(unit_defs.get(def_name), other.def_name)
end

-- Everything standing in the way of a footprint at `position`.
local function overlapping(def_name: string, position: Vector3, facing: number, ignore_id: EntityId?): { Entity }
	local def = unit_defs.get(def_name)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
	local found: { Entity } = {}
	for id, other in state.all() do
		if other.alive == false or id == ignore_id or air.is_airborne(other) or is_upgrade_target(def_name, other) then
			continue
		end
		if geometry.aabb_overlap(position, half, other.position, half_extents_for(other), OVERLAP_PADDING) then
			table.insert(found, other)
		end
	end
	return found
end

-- Returns whether the footprint is clear, and a short reason when it is not. Given a `clearing_team`, what
-- that team can clear away, wrecks and its own movable units, is not counted as being in the way: removing
-- it is the job of the builder, once it gets there.
local function can_place(
	def_name: string,
	position: Vector3,
	facing: number,
	ignore_id: EntityId?,
	clearing_team: types.TeamId?
): (boolean, string?)
	local def = unit_defs.get(def_name)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)

	if heightmap.in_bounds(position.X - half.X, position.Z - half.Y) == false then
		return false, "out of bounds"
	end
	if heightmap.in_bounds(position.X + half.X, position.Z + half.Y) == false then
		return false, "out of bounds"
	end

	if def.kind == "building" then
		local grid_x, grid_z = geometry.snap_center(position.X, position.Z, half, config.CELL_STUDS)
		if math.abs(grid_x - position.X) > GRID_TOLERANCE or math.abs(grid_z - position.Z) > GRID_TOLERANCE then
			return false, "off the grid"
		end
	end

	local bound_to = spots.for_def(def)
	if bound_to ~= nil then
		-- placement snaps onto a spot before it gets here, so anything not exactly on one is off it
		if bound_to.nearest(position.X, position.Z, SPOT_MATCH_RADIUS) == nil then
			return false, if def.requires_geo_spot == true then "needs a geothermal vent" else "needs a metal spot"
		end
	end

	local lowest, highest = heightmap.height_range(position.X, position.Z, half.X, half.Y)
	if def.kind == "building" and highest - lowest > config.MAX_BUILD_SLOPE_STUDS then
		return false, "ground too steep"
	end
	local deepest = math.max(0, config.WATER_LEVEL - lowest)
	local shallowest = math.max(0, config.WATER_LEVEL - highest)
	if unit_defs.tolerates_water(def, shallowest, deepest) == false then
		return false, if deepest > def.max_water_depth then "water too deep" else "water too shallow"
	end

	for id, other in state.all() do
		if other.alive == false then
			continue
		end
		if id == ignore_id then
			continue
		end
		-- an aircraft that is up in the air is over whatever is put down beneath it
		if air.is_airborne(other) then
			continue
		end
		if clearing_team ~= nil and clearable(other, clearing_team) then
			continue
		end
		if is_upgrade_target(def_name, other) then
			continue
		end
		if geometry.aabb_overlap(position, half, other.position, half_extents_for(other), OVERLAP_PADDING) then
			return false, "blocked"
		end
	end

	return true, nil
end

-- Drops a footprint's centre onto what it rests on, so it sits on the terrain rather than in it, or on the
-- water's surface if it floats.
local function ground_center(def_name: string, x: number, z: number): Vector3
	local def = unit_defs.get(def_name)
	return Vector3.new(x, unit_defs.surface_height(def, x, z) + unit_defs.collider_height(def) / 2, z)
end

-- Whether something spot-bound already stands on `spot`, or is waiting in a builder's queue to.
-- If `builder_id` is provided, only that builder's own queue counts: it won't snap onto a spot it has already
-- queued, but may snap onto one another builder has queued. With no builder, every queue counts.
-- Spots with what `def_name` is built over in place (`EntityDef.upgrades`) on them are not considered taken.
local function spot_taken(spot: Vector3, builder_id: EntityId?, def_name: string?): boolean
	for _, other in state.all() do
		if other.alive == false then
			continue
		end
		if other.kind == "building" and spots.for_def(unit_defs.of(other)) ~= nil then
			-- a T2 mex may go on a spot a T1 mex already stands on (fix #4), and an advanced geothermal on a vent a
			-- plain one does
			if def_name ~= nil and is_upgrade_target(def_name, other) then
				continue
			end
			if geometry.distance_2d(other.position, spot) < TAKEN_RADIUS then
				return true
			end
		end
		for _, order in other.orders do
			local queued_def = if order.kind == "build" and order.def_name ~= nil
				then unit_defs.of(order)
				else nil
			if queued_def ~= nil and spots.for_def(queued_def) ~= nil and order.position ~= nil then
				-- another builder's queued mex doesn't take the spot from this one (fix #10)
				if builder_id ~= nil and other.id ~= builder_id then
					continue
				end
				if geometry.distance_2d(order.position, spot) < TAKEN_RADIUS then
					return true
				end
			end
		end
	end
	return false
end

-- Where a building asked for at (x, z) would actually go, turned to `facing`. Buildings sit on the
-- building grid, and a spot-bound one goes on the nearest spot of its kind instead, a metal spot or a geothermal vent,
-- or nowhere if there is none close enough. If `builder_id` is provided and this is a spot-bound building, only
-- spots queued by that builder are taken, not those other builders have queued. Something built over another in place can use spots that other
-- already stands on.
local function resolve_center(def_name: string, x: number, z: number, facing: number, builder_id: EntityId?): Vector3?
	local def = unit_defs.get(def_name)
	local bound_to = spots.for_def(def)
	if bound_to ~= nil then
		local spot = bound_to.nearest(x, z, config.METAL_SPOT_SNAP, function(s)
			return spot_taken(s, builder_id, def_name)
		end)
		if spot == nil then
			return nil
		end
		return ground_center(def_name, spot.X, spot.Z)
	end
	if def.kind == "building" then
		local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
		local grid_x, grid_z = geometry.snap_center(x, z, half, config.CELL_STUDS)
		return ground_center(def_name, grid_x, grid_z)
	end
	return ground_center(def_name, x, z)
end

return table.freeze({
	can_place = can_place,
	overlapping = overlapping,
	clearable = clearable,
	ground_center = ground_center,
	resolve_center = resolve_center,
	half_extents_for = half_extents_for,
})
