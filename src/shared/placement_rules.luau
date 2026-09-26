--!strict
-- Where a footprint goes, whether it can go there, and which spots are spoken for, as both sides judge it: the server
-- before it puts anything down (server/placement.luau), and the client as it carries the ghost of a building round
-- (client/build_mode.luau) and as it hides the spots already built on (client/spot_markers.luau). The two see the map differently, the server as entities and the client as their models, so
-- each hands the rules a view of what stands on it (`Occupants`), and the rules are the same.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local surface = require(ReplicatedStorage.Shared.surface)
local spots = require(ReplicatedStorage.Shared.spots)
local geometry = require(ReplicatedStorage.Shared.geometry)

type EntityDef = types.EntityDef
type EntityKind = types.EntityKind
type EntityState = types.EntityState

-- What is wrong with a place for a footprint: it reaches off the map, is off the building grid, is not on the metal
-- spot or geothermal vent it has to stand on, the ground is too steep, it needs water there and there is none, or not
-- deep enough, it cannot stand in water and there is some, or the water is too deep, or something is in the way.
export type Problem =
	"outside_map"
	| "off_grid"
	| "needs_metal_spot"
	| "needs_geo_vent"
	| "too_steep"
	| "needs_water"
	| "needs_deeper_water"
	| "no_water"
	| "too_deep"
	| "blocked"

-- What stands on the map, as one side sees it: `T` is however that side holds a thing.
export type Occupants<T> = {
	-- calls `visit` with everything that could be within `radius` of (x, z), give or take its own collider
	each_near: (x: number, z: number, radius: number, visit: (T) -> ()) -> (),
	kind: (T) -> EntityKind?,
	def: (T) -> EntityDef?,
	position: (T) -> Vector3,
	facing: (T) -> number,
	-- whether it is up in the air, over whatever is put down beneath it
	airborne: (T) -> boolean,
	-- whether the builder putting the footprint down clears it off when it gets there (`clearable`)
	clearable: (T) -> boolean,
}

-- Footprints are allowed to touch; only real overlap is rejected.
local OVERLAP_PADDING = 0
-- How far off its grid position a building may be, only there to forgive float error.
local GRID_TOLERANCE = 0.01
-- How close something has to be to a spot to be sitting on it or headed for it. The client reads where builds are
-- queued in whole studs (shared/order_path), which is well within this.
local TAKEN_RADIUS = 1

-- The half extents of the footprint of `def` turned to `facing`.
local function footprint(def: EntityDef, facing: number): Vector2
	return geometry.rotated_half_extents(unit_defs.footprint_half_extents(def), facing)
end

-- Whether something in the way of a footprint can be moved off it: a wreck or a reclaimable, which is reclaimed, or,
-- when it is the placing team's (`own`), one of its units that can move, which is sent away.
local function clearable(kind: EntityKind, state: EntityState, def: EntityDef, own: boolean): boolean
	if kind == "wreck" or kind == "reclaimable" then
		return true
	end
	return state == "active" and own and unit_defs.moves(def)
end

-- Whether a thing of `kind` and `other_def_name` is what `def` is built over in place (`EntityDef.upgrades`), a T1 mex
-- under a T2 one or a geothermal plant under an advanced one: it neither blocks the footprint nor takes the spot.
local function is_upgrade_target(def: EntityDef, kind: EntityKind?, other_def_name: string): boolean
	return kind == "building" and spots.upgrades(def, other_def_name)
end

-- How far from a footprint's middle, of half extents `half`, the middle of anything overlapping it can be, give or take
-- its own collider: a footprint reaches out past its collider by less than a cell a side.
local function reach_of(half: Vector2): number
	return half.Magnitude + world_scale.CELL_STUDS
end

-- What is wrong with the ground itself at `position` for a footprint of `def` turned to `facing`, whatever stands on
-- it, if anything.
local function ground_problem(def: EntityDef, position: Vector3, facing: number): Problem?
	local half = footprint(def, facing)
	if
		heightmap.in_bounds(position.X - half.X, position.Z - half.Y) == false
		or heightmap.in_bounds(position.X + half.X, position.Z + half.Y) == false
	then
		return "outside_map"
	end

	if def.kind == "building" then
		local grid_x, grid_z = geometry.snap_center(position.X, position.Z, half, world_scale.CELL_STUDS)
		if math.abs(grid_x - position.X) > GRID_TOLERANCE or math.abs(grid_z - position.Z) > GRID_TOLERANCE then
			return "off_grid"
		end
	end

	local bound_to: types.SpotKind? = def.spot
	-- placement snaps onto a spot before it gets here, so anything not exactly on one is off it
	if bound_to ~= nil and spots.on_spot(bound_to, position) == false then
		return if bound_to == "geo" then "needs_geo_vent" else "needs_metal_spot"
	end

	local lowest, highest = heightmap.height_range(position.X, position.Z, half.X, half.Y)
	if def.kind == "building" and highest - lowest > ground_levels.MAX_BUILD_SLOPE_STUDS then
		return "too_steep"
	end
	local deepest = math.max(0, ground_levels.WATER_LEVEL - lowest)
	local shallowest = math.max(0, ground_levels.WATER_LEVEL - highest)
	if unit_defs.tolerates_water(def, shallowest, deepest) == false then
		if shallowest < def.footing.min_depth then
			-- some of it is on dry land, or it is in water but not deep enough to float
			return if shallowest <= 0 then "needs_water" else "needs_deeper_water"
		end
		return if def.footing.max_depth <= 0 then "no_water" else "too_deep"
	end
	return nil
end

-- Calls `visit` with everything a footprint of `def` at `position`, turned to `facing`, overlaps, save what is up in
-- the air over it and what `def` is built over in place.
local function each_in_the_way<T>(
	occupants: Occupants<T>,
	def: EntityDef,
	position: Vector3,
	facing: number,
	visit: (T) -> ()
)
	local half = footprint(def, facing)
	occupants.each_near(position.X, position.Z, reach_of(half), function(other: T)
		local other_def = occupants.def(other)
		if
			other_def == nil
			or occupants.airborne(other)
			or is_upgrade_target(def, occupants.kind(other), other_def.name)
		then
			return
		end
		local other_half = footprint(other_def, occupants.facing(other))
		if geometry.aabb_overlap(position, half, occupants.position(other), other_half, OVERLAP_PADDING) then
			visit(other)
		end
	end)
end

-- What is wrong with putting a footprint of `def_name` at `position`, turned to `facing`, if anything: the ground
-- (`ground_problem`), or something in the way that the builder does not clear off (`Occupants.clearable`). `skip`,
-- the builder itself, is never in its own way.
local function problem<T>(occupants: Occupants<T>, def_name: string, position: Vector3, facing: number, skip: T?): Problem?
	local def = unit_defs.get(def_name)
	local wrong: Problem? = ground_problem(def, position, facing)
	if wrong ~= nil then
		return wrong
	end
	local blocked = false
	each_in_the_way(occupants, def, position, facing, function(other: T)
		if blocked == false and other ~= skip and occupants.clearable(other) == false then
			blocked = true
		end
	end)
	if blocked then
		return "blocked"
	end
	return nil
end

-- Whether something spot-bound stands on `spot`, finished or not, other than what something of `over` is built over in
-- place (`EntityDef.upgrades`); without `over`, whatever stands there.
local function spot_built_on<T>(occupants: Occupants<T>, spot: Vector3, over: EntityDef?): boolean
	local built_on = false
	occupants.each_near(spot.X, spot.Z, TAKEN_RADIUS, function(other: T)
		local other_def = occupants.def(other)
		local kind = occupants.kind(other)
		if
			built_on
			or other_def == nil
			or kind ~= "building"
			or other_def.spot == nil
			or (over ~= nil and is_upgrade_target(over, kind, other_def.name))
		then
			return
		end
		if geometry.distance_2d(occupants.position(other), spot) < TAKEN_RADIUS then
			built_on = true
		end
	end)
	return built_on
end

-- Whether `spot` is spoken for, for something spot-bound of `def` to go on: something spot-bound stands on it that `def`
-- is not built over in place (`spot_built_on`), or the builder that would put it there already has a build queued onto
-- it (`queued`, where it has spot-bound builds queued). Another builder's queue does not take it: two builders sent to
-- one spot share the one blueprint.
local function spot_taken<T>(occupants: Occupants<T>, def: EntityDef, spot: Vector3, queued: { Vector3 }): boolean
	for _, at in queued do
		if geometry.distance_2d(at, spot) < TAKEN_RADIUS then
			return true
		end
	end
	return spot_built_on(occupants, spot, def)
end

-- The middle of something of `def` standing at (x, z): on the terrain rather than in it, or on the water's surface if
-- it floats.
local function ground_center(def: EntityDef, x: number, z: number): Vector3
	return Vector3.new(x, surface.height(def, x, z) + unit_defs.collider_height(def) / 2, z)
end

-- The middle of a building of `def` asked for at (x, z), turned to `facing`, snapped onto the building grid.
local function grid_center(def: EntityDef, x: number, z: number, facing: number): Vector3
	local grid_x, grid_z = geometry.snap_center(x, z, footprint(def, facing), world_scale.CELL_STUDS)
	return ground_center(def, grid_x, grid_z)
end

-- Where something of `def` asked for at (x, z) would actually go, turned to `facing`. A building sits on the building
-- grid (`grid_center`), and a spot-bound one goes on the nearest spot of its kind instead, a metal spot or a geothermal
-- vent, that is not spoken for (`spot_taken`, `queued` being where the builder has spot-bound builds queued), however
-- far away it is, or nowhere if every one is. Anything else goes where it is asked for.
local function resolve_center<T>(
	occupants: Occupants<T>,
	def: EntityDef,
	x: number,
	z: number,
	facing: number,
	queued: { Vector3 }
): Vector3?
	local bound_to: types.SpotKind? = def.spot
	if bound_to ~= nil then
		local spot = spots.nearest(bound_to, x, z, math.huge, function(candidate: Vector3): boolean
			return spot_taken(occupants, def, candidate, queued)
		end)
		return if spot ~= nil then ground_center(def, spot.X, spot.Z) else nil
	end
	if def.kind == "building" then
		return grid_center(def, x, z, facing)
	end
	return ground_center(def, x, z)
end

return table.freeze({
	footprint = footprint,
	clearable = clearable,
	ground_problem = ground_problem,
	each_in_the_way = each_in_the_way,
	problem = problem,
	spot_built_on = spot_built_on,
	spot_taken = spot_taken,
	ground_center = ground_center,
	grid_center = grid_center,
	resolve_center = resolve_center,
})
