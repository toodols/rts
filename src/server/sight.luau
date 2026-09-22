-- Line of sight. Whether a shooter can see its target, and what stands in the way when it cannot.
--
-- A shot is blocked by the ground, or by something solid between the two: a finished unit or building.
-- Blocked by ground, the shooter never fires. Blocked by something on its own side, it holds fire too,
-- which is the caller's business, and blocked by an enemy it fires as normal and the enemy takes the
-- shot. Wrecks and blueprints are not in the way of anything.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local state = require(script.Parent.state)
local alliances = require(script.Parent.alliances)

type Entity = types.Entity
type EntityId = types.EntityId

export type Verdict = "clear" | "terrain" | "friendly"

-- Shots leave from this far above the middle of the shooter, as a fraction of its height.
local MUZZLE_FRACTION = 0.25
-- How far above the ground the line has to stay, and how often along it the ground is sampled.
local TERRAIN_MARGIN = 0.4
local SAMPLE_STEP = 2
-- Slack on how far above or below something a line can pass and still touch it.
local HEIGHT_SLACK = 0.5

-- What might stand in a line's way is found through a flat (X, Z) grid rebuilt once a tick (see
-- begin_tick), not by testing every entity on the map against every line: a check only visits the
-- cells near its own segment.
local LOS_CELL = 24
-- How far the grid can be out of date by the time a check reads it: it is built at the start of the
-- tick, before anything has moved, so a line is searched this much wider to still catch something that
-- has since stepped into it. Well over what the fastest unit covers in one tick.
local MOVE_SLACK = 8

local grid: { [number]: { [number]: { Entity } } } = {}

-- The widest collider of anything that can exist, so a cell is only skipped when nothing standing in it
-- could reach the line.
local widest_collider = 0
for _, def in unit_defs.defs do
	widest_collider = math.max(widest_collider, unit_defs.collider_radius(def))
end

local function begin_tick()
	table.clear(grid)
	for _, entity in state.all() do
		if entity.alive == false then
			continue
		end
		local gx = math.floor(entity.position.X / LOS_CELL)
		local gz = math.floor(entity.position.Z / LOS_CELL)
		local column = grid[gx]
		if column == nil then
			column = {}
			grid[gx] = column
		end
		local bucket = column[gz]
		if bucket == nil then
			bucket = {}
			column[gz] = bucket
		end
		table.insert(bucket, entity)
	end
end

-- Calls `visit` with everything in a cell close enough to the segment from `from` to `to` that
-- something standing in it could touch the line. Each entity is in exactly one cell, so none is visited
-- twice.
local function each_near_segment(from: Vector3, to: Vector3, visit: (Entity) -> ())
	local pad = widest_collider + MOVE_SLACK
	-- a cell counts if the line passes within this of its centre: half its diagonal, plus the padding
	local reach = LOS_CELL * 0.7072 + pad
	local ax, az = from.X, from.Z
	local dx, dz = to.X - ax, to.Z - az
	local length_squared = dx * dx + dz * dz
	local min_gx = math.floor((math.min(ax, to.X) - pad) / LOS_CELL)
	local max_gx = math.floor((math.max(ax, to.X) + pad) / LOS_CELL)
	local min_gz = math.floor((math.min(az, to.Z) - pad) / LOS_CELL)
	local max_gz = math.floor((math.max(az, to.Z) + pad) / LOS_CELL)
	for gx = min_gx, max_gx do
		local column = grid[gx]
		if column == nil then
			continue
		end
		for gz = min_gz, max_gz do
			local bucket = column[gz]
			if bucket == nil then
				continue
			end
			local cx = (gx + 0.5) * LOS_CELL - ax
			local cz = (gz + 0.5) * LOS_CELL - az
			local t = if length_squared > 1e-6 then math.clamp((cx * dx + cz * dz) / length_squared, 0, 1) else 0
			local ox, oz = cx - dx * t, cz - dz * t
			if ox * ox + oz * oz > reach * reach then
				continue
			end
			for _, entity in bucket do
				visit(entity)
			end
		end
	end
end

local function muzzle_of(shooter: Entity): Vector3
	local height = unit_defs.collider_height(unit_defs.get(shooter.def_name))
	return shooter.position + Vector3.new(0, height * MUZZLE_FRACTION, 0)
end

local function ground_blocks(from: Vector3, to: Vector3): boolean
	local steps = math.floor((to - from).Magnitude / SAMPLE_STEP)
	for step = 1, steps do
		local point = from:Lerp(to, step / (steps + 1))
		if point.Y < heightmap.height_at(point.X, point.Z) + TERRAIN_MARGIN then
			return true
		end
	end
	return false
end

-- Whether the ground gets in the way of a shell that flies through `path`.
local function path_blocked(path: { Vector3 }): boolean
	for _, point in path do
		if point.Y < heightmap.height_at(point.X, point.Z) + TERRAIN_MARGIN then
			return true
		end
	end
	return false
end

-- The first solid thing the line from `from` to `to` touches, other than the two `ignored`, if any.
local function first_in_way(from: Vector3, to: Vector3, ignored_a: EntityId, ignored_b: EntityId): Entity?
	local along = Vector2.new(to.X - from.X, to.Z - from.Z)
	local length_squared = along:Dot(along)

	local nearest: Entity? = nil
	local nearest_t = math.huge
	each_near_segment(from, to, function(other: Entity)
		if other.alive == false or other.id == ignored_a or other.id == ignored_b then
			return
		end
		if other.kind == "wreck" or other.state ~= "active" then
			return
		end

		local def = unit_defs.get(other.def_name)
		local to_other = Vector2.new(other.position.X - from.X, other.position.Z - from.Z)
		local t = if length_squared > 1e-6 then math.clamp(to_other:Dot(along) / length_squared, 0, 1) else 0
		local closest = from:Lerp(to, t)

		local sideways = Vector2.new(closest.X - other.position.X, closest.Z - other.position.Z).Magnitude
		local vertical = math.abs(closest.Y - other.position.Y)
		if
			sideways <= unit_defs.collider_radius(def)
			and vertical <= unit_defs.collider_height(def) / 2 + HEIGHT_SLACK
			and t < nearest_t
		then
			nearest = other
			nearest_t = t
		end
	end)
	return nearest
end

-- Whether `shooter`, firing from `origin`, has a shot at `target`.
local function verdict(shooter: Entity, target: Entity, origin: Vector3): Verdict
	if ground_blocks(origin, target.position) then
		return "terrain"
	end
	local blocker = first_in_way(origin, target.position, shooter.id, target.id)
	if blocker ~= nil and alliances.are_allied(blocker.team, shooter.team) then
		return "friendly"
	end
	return "clear"
end

-- Like `verdict`, for a shell that arcs: the ground can only block the arc it really flies, `path`, and not the
-- straight line to the target, which it goes over. What stands in its way is still judged on that line.
local function verdict_along(shooter: Entity, target_position: Vector3, origin: Vector3, path: { Vector3 }, ignored: EntityId): Verdict
	if path_blocked(path) then
		return "terrain"
	end
	local blocker = first_in_way(origin, target_position, shooter.id, ignored)
	if blocker ~= nil and alliances.are_allied(blocker.team, shooter.team) then
		return "friendly"
	end
	return "clear"
end

-- How far above the ground a bare point is aimed at for the ground to be judged. A point is the ground itself,
-- and a long shot to it skims so low along the way that the smallest bump in front of it would count as in the way.
local POINT_LIFT = 2

-- Whether `shooter`, firing from `origin`, has a shot at a bare `point` on the ground, where there is no
-- target to see: the ground and its own side can block it, and nothing else does.
local function verdict_to_point(shooter: Entity, point: Vector3, origin: Vector3): Verdict
	if ground_blocks(origin, point + Vector3.new(0, POINT_LIFT, 0)) then
		return "terrain"
	end
	local blocker = first_in_way(origin, point, shooter.id, shooter.id)
	if blocker ~= nil and alliances.are_allied(blocker.team, shooter.team) then
		return "friendly"
	end
	return "clear"
end

-- The first wreck the line from `from` to `to` touches, if any. Wrecks can be hit by hitscan weapons like beam lasers.
local function first_wreck_in_way(from: Vector3, to: Vector3, ignored_a: EntityId, ignored_b: EntityId): Entity?
	local along = Vector2.new(to.X - from.X, to.Z - from.Z)
	local length_squared = along:Dot(along)

	local nearest: Entity? = nil
	local nearest_t = math.huge
	each_near_segment(from, to, function(other: Entity)
		if other.alive == false or other.kind ~= "wreck" then
			return
		end
		if other.id == ignored_a or other.id == ignored_b then
			return
		end

		local def = unit_defs.get(other.def_name)
		local to_other = Vector2.new(other.position.X - from.X, other.position.Z - from.Z)
		local t = if length_squared > 1e-6 then math.clamp(to_other:Dot(along) / length_squared, 0, 1) else 0
		local closest = from:Lerp(to, t)

		local sideways = Vector2.new(closest.X - other.position.X, closest.Z - other.position.Z).Magnitude
		local vertical = math.abs(closest.Y - other.position.Y)
		if
			sideways <= unit_defs.collider_radius(def)
			and vertical <= unit_defs.collider_height(def) / 2 + HEIGHT_SLACK
			and t < nearest_t
		then
			nearest = other
			nearest_t = t
		end
	end)
	return nearest
end

-- What a shot aimed at `target` actually strikes: whatever solid thing is first in its way, which is
-- the target itself unless something stands between. Wrecks can be hit by hitscan weapons like beam lasers.
local function first_hit(shooter: Entity, target: Entity, origin: Vector3): Entity
	local blocker = first_in_way(origin, target.position, shooter.id, target.id)
	if blocker ~= nil then
		return blocker
	end
	-- Check for wrecks between shooter and target
	local wreck = first_wreck_in_way(origin, target.position, shooter.id, target.id)
	if wreck ~= nil then
		return wreck
	end
	return target
end

-- What a shot aimed at a bare `point` strikes, if anything: an enemy standing on the line to it.
local function first_hit_at(shooter: Entity, point: Vector3, origin: Vector3): Entity?
	return first_in_way(origin, point, shooter.id, shooter.id)
end

return table.freeze({
	begin_tick = begin_tick,
	muzzle_of = muzzle_of,
	verdict = verdict,
	verdict_to_point = verdict_to_point,
	verdict_along = verdict_along,
	first_hit = first_hit,
	first_hit_at = first_hit_at,
})
