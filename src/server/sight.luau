-- Line of sight. Whether a shooter can see what it aims at, and what stands in the way when it cannot.
--
-- A shot is aimed at something on the map or at a bare point on the ground (`Aim`). It is blocked by the ground, or by
-- something solid between: a finished unit or building. Blocked by ground, the shooter never fires. Blocked by
-- something on its own side, it holds fire too, which is the caller's business, and blocked by an enemy it fires as
-- normal and the enemy takes the shot. Wrecks and blueprints never block a shot, though a beam that meets a wreck on
-- its way strikes it (`first_hit`); aircraft, which as in BAR have no collider, are passed through by a shot at
-- anything but themselves.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local alliances = require(script.Parent.alliances)
local spatial = require(script.Parent.spatial)

type Entity = types.Entity
type EntityId = types.EntityId

export type Verdict = "clear" | "terrain" | "friendly"

-- What a shot is aimed at: something on the map, or a bare point on the ground.
export type Aim = Entity | Vector3

-- How far above the ground the line has to stay, and how often along it the ground is sampled.
local TERRAIN_MARGIN = 0.4
local SAMPLE_STEP = 2

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

-- Where `aim` is.
local function position_of(aim: Aim): Vector3
	if typeof(aim) == "Vector3" then
		return aim
	end
	return aim.position
end

-- How fast `aim` is going: the ground stays where it is.
local function velocity_of(aim: Aim): Vector3
	if typeof(aim) == "Vector3" then
		return Vector3.zero
	end
	return aim.velocity
end

-- What `aim` is, if it is something on the map rather than the ground.
local function target_of(aim: Aim): Entity?
	if typeof(aim) == "Vector3" then
		return nil
	end
	return aim
end

-- How far above the ground a bare point is aimed at for the ground to be judged. A point is the ground itself,
-- and a long shot to it skims so low along the way that the smallest bump in front of it would count as in the way.
local POINT_LIFT = 2

-- Where the line from `shooter` to `aim` goes, and the other thing it leaves out besides the shooter: what it is aimed
-- at, if it is aimed at something.
local function line_to(shooter: Entity, aim: Aim): (Vector3, EntityId)
	local target = target_of(aim)
	if target == nil then
		return position_of(aim), shooter.id
	end
	return target.position, target.id
end

-- Whether `shooter`, firing from `origin`, has a shot at `aim`. The ground is judged along the straight line to it, or
-- for a shell that arcs along `path`, the arc it really flies, since it goes over the line; a bare point, which is the
-- ground, a little above it (POINT_LIFT). What stands in its way is judged on the straight line either way.
local function verdict(shooter: Entity, aim: Aim, origin: Vector3, path: { Vector3 }?): Verdict
	local to, ignored = line_to(shooter, aim)
	if path ~= nil then
		if path_blocked(path) then
			return "terrain"
		end
	elseif ground_blocks(origin, if target_of(aim) == nil then to + Vector3.new(0, POINT_LIFT, 0) else to) then
		return "terrain"
	end
	local blocker = spatial.first_blocker(origin, to, shooter.id, ignored)
	if blocker ~= nil and alliances.are_allied(blocker.team, shooter.team) then
		return "friendly"
	end
	return "clear"
end

-- What a shot at `aim` from `origin` actually strikes: whatever is first on the line to it, a solid thing or else a
-- wreck, and failing both what it was aimed at, if it was aimed at something.
local function first_hit(shooter: Entity, aim: Aim, origin: Vector3): Entity?
	local to, ignored = line_to(shooter, aim)
	local blocker = spatial.first_blocker(origin, to, shooter.id, ignored)
	if blocker ~= nil then
		return blocker
	end
	local wreck = spatial.first_wreck(origin, to, shooter.id, ignored)
	if wreck ~= nil then
		return wreck
	end
	return target_of(aim)
end

return table.freeze({
	position_of = position_of,
	velocity_of = velocity_of,
	target_of = target_of,
	verdict = verdict,
	first_hit = first_hit,
})
