-- Line of sight. Whether a shooter can see its target, and what stands in the way when it cannot.
--
-- A shot is blocked by the ground, or by something solid between the two: a finished unit or building.
-- Blocked by ground, the shooter never fires. Blocked by something on its own side, it holds fire too,
-- which is the caller's business, and blocked by an enemy it fires as normal and the enemy takes the
-- shot. Wrecks and blueprints are not in the way of anything, and neither are aircraft, which as in BAR have no
-- collider: a shot passes through any aircraft but the one it is aimed at.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local state = require(script.Parent.state)
local alliances = require(script.Parent.alliances)
local flat_grid = require(script.Parent.flat_grid)
local air = require(script.Parent.air)

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

-- What might stand in a line's way is found through flat grids (see flat_grid.luau), not by testing
-- every entity on the map against every line: a check only visits the cells near its own segment. A
-- cell counts as near if the line passes within half its diagonal plus the widest collider it can hold,
-- so small units and big buildings live in separate grids - one cell size for both would have to allow
-- for a building's width everywhere, widening every check through a crowd of small units several times
-- over. Wrecks never block a line, only a hitscan shot can strike one, so they have a grid of their own.
--
-- The grids are marked stale both before orders (whose fight orders ask for sight) and again after
-- movement, before combat fires (see `invalidate`), so every check reads exactly where things stand. A
-- stale grid is only rebuilt when something actually asks - so a tick in which nothing looks costs
-- nothing, which is most ticks for most of a map that is not at war.
local SMALL_RADIUS = 4

local widest_collider = 0
for _, def in unit_defs.defs do
	widest_collider = math.max(widest_collider, unit_defs.collider_radius(def))
end

type Layer = {
	grid: flat_grid.Grid,
	-- the widest collider this layer can hold
	widest: number,
	ys: { number },
	half_heights: { number },
	ids: { EntityId },
	entities: { Entity },
}

local function new_layer(cell: number, side: number, widest: number): Layer
	return {
		grid = flat_grid.new(cell, side),
		widest = widest,
		ys = {},
		half_heights = {},
		ids = {},
		entities = {},
	}
end

local small_blockers = new_layer(8, 256, SMALL_RADIUS)
local large_blockers = new_layer(24, 64, widest_collider)
local wrecks = new_layer(24, 64, widest_collider)

local function layer_add(layer: Layer, entity: Entity, radius: number, half_height: number)
	local position = entity.position
	local k = flat_grid.add(layer.grid, position.X, position.Z, radius)
	layer.ys[k] = position.Y
	layer.half_heights[k] = half_height
	layer.ids[k] = entity.id
	layer.entities[k] = entity
end

local stale = true

local function invalidate()
	stale = true
end

local function rebuild()
	stale = false
	flat_grid.clear(small_blockers.grid)
	flat_grid.clear(large_blockers.grid)
	flat_grid.clear(wrecks.grid)
	for _, entity in state.all() do
		-- a reclaimable is in the way of no line of fire, and no shot can strike it
		if entity.alive == false or entity.kind == "reclaimable" then
			continue
		end
		local def = unit_defs.of(entity)
		local radius = unit_defs.collider_radius(def)
		local half_height = unit_defs.collider_height(def) / 2
		if entity.kind == "wreck" then
			layer_add(wrecks, entity, radius, half_height)
		-- what is wholly under the water is under every line of fire as well: nothing can hit it that way, and it is
		-- not in the way of anything
		elseif
			entity.state == "active"
			and air.is_aircraft(entity) == false
			and unit_defs.submerged(def, entity.position) == false
		then
			layer_add(if radius <= SMALL_RADIUS then small_blockers else large_blockers, entity, radius, half_height)
		end
	end
	flat_grid.sort(small_blockers.grid)
	flat_grid.sort(large_blockers.grid)
	flat_grid.sort(wrecks.grid)
end

-- The nearest thing in `layer` the line from `from` to `to` touches, nearer than `best_t` along it (0 at
-- `from`, 1 at `to`), other than the two `ignored`: its position along the line, and the thing itself.
local function nearest_on_segment(
	layer: Layer,
	from: Vector3,
	to: Vector3,
	ignored_a: EntityId,
	ignored_b: EntityId,
	best_t: number
): (number, Entity?)
	local grid = layer.grid
	local size, side = grid.size, grid.side
	local xs, zs, rs, order, starts, stops = grid.xs, grid.zs, grid.rs, grid.order, grid.starts, grid.stops
	local ys, half_heights, ids, entities = layer.ys, layer.half_heights, layer.ids, layer.entities
	local pad = layer.widest
	local reach = size * 0.7072 + pad
	local ax, ay, az = from.X, from.Y, from.Z
	local dx, dy, dz = to.X - ax, to.Y - ay, to.Z - az
	local length_squared = dx * dx + dz * dz
	local best: Entity? = nil
	for gx = math.floor((math.min(ax, to.X) - pad) / size), math.floor((math.max(ax, to.X) + pad) / size) do
		for gz = math.floor((math.min(az, to.Z) - pad) / size), math.floor((math.max(az, to.Z) + pad) / size) do
			local c = (gz % side) * side + (gx % side) + 1
			local first = starts[c]
			if first == 0 then
				continue
			end
			-- skip a cell the line passes too far from for anything in it to touch
			local cx = (gx + 0.5) * size - ax
			local cz = (gz + 0.5) * size - az
			local tc = if length_squared > 1e-6 then math.clamp((cx * dx + cz * dz) / length_squared, 0, 1) else 0
			local ocx, ocz = cx - dx * tc, cz - dz * tc
			if ocx * ocx + ocz * ocz > reach * reach then
				continue
			end
			for s = first, stops[c] - 1 do
				local k = order[s]
				local id = ids[k]
				if id == ignored_a or id == ignored_b then
					continue
				end
				local ox, oz = xs[k] - ax, zs[k] - az
				local t = if length_squared > 1e-6 then math.clamp((ox * dx + oz * dz) / length_squared, 0, 1) else 0
				if t >= best_t then
					continue
				end
				local sx, sz = ox - dx * t, oz - dz * t
				local radius = rs[k]
				if sx * sx + sz * sz > radius * radius then
					continue
				end
				if math.abs(ay + dy * t - ys[k]) > half_heights[k] + HEIGHT_SLACK then
					continue
				end
				local entity = entities[k]
				-- something can die after the rebuild, part way through combat's own tick
				if entity.alive == false then
					continue
				end
				best = entity
				best_t = t
			end
		end
	end
	return best_t, best
end

local function muzzle_of(shooter: Entity): Vector3
	local height = unit_defs.collider_height(unit_defs.of(shooter))
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
	if stale then
		rebuild()
	end
	local best_t, nearest = nearest_on_segment(small_blockers, from, to, ignored_a, ignored_b, math.huge)
	local _, large = nearest_on_segment(large_blockers, from, to, ignored_a, ignored_b, best_t)
	return large or nearest
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
local function verdict_along(
	shooter: Entity,
	target_position: Vector3,
	origin: Vector3,
	path: { Vector3 },
	ignored: EntityId
): Verdict
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
	if stale then
		rebuild()
	end
	local _, nearest = nearest_on_segment(wrecks, from, to, ignored_a, ignored_b, math.huge)
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
	invalidate = invalidate,
	muzzle_of = muzzle_of,
	verdict = verdict,
	verdict_to_point = verdict_to_point,
	verdict_along = verdict_along,
	first_hit = first_hit,
	first_hit_at = first_hit_at,
})
