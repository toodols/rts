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
	for _, other in state.all() do
		if other.alive == false or other.id == ignored_a or other.id == ignored_b then
			continue
		end
		if other.kind == "wreck" or other.state ~= "active" then
			continue
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
	end
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

-- What a shot aimed at `target` actually strikes: whatever solid thing is first in its way, which is
-- the target itself unless something stands between.
local function first_hit(shooter: Entity, target: Entity, origin: Vector3): Entity
	local blocker = first_in_way(origin, target.position, shooter.id, target.id)
	if blocker ~= nil then
		return blocker
	end
	return target
end

-- What a shot aimed at a bare `point` strikes, if anything: an enemy standing on the line to it.
local function first_hit_at(shooter: Entity, point: Vector3, origin: Vector3): Entity?
	return first_in_way(origin, point, shooter.id, shooter.id)
end

return table.freeze({
	muzzle_of = muzzle_of,
	verdict = verdict,
	verdict_to_point = verdict_to_point,
	verdict_along = verdict_along,
	first_hit = first_hit,
	first_hit_at = first_hit_at,
})
