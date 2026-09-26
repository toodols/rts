-- What stands between a weapon choosing what to shoot and firing at it: its turret has to turn to face it. Where it
-- points is simulation state on the entity (`Entity.weapon_aims`), so a shot waits on it exactly, the same way every
-- time; the client only draws what it already is.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local geometry = require(ReplicatedStorage.Shared.geometry)

type Entity = types.Entity
type EntityId = types.EntityId

-- How near a weapon's turret has to point to what it is shooting before it fires, in radians, and how long it
-- waits with nothing to shoot before turning back to face ahead, in seconds.
local TURRET_TOLERANCE = math.rad(3)
local TURRET_REST_DELAY = 3

-- Seconds each turret has had nothing to aim at, by entity and weapon, for turning back to face ahead.
local idle_for: { [EntityId]: { [number]: number } } = {}

-- Turns weapon `index`'s turret a tick's worth toward `aim_point`, seen from `origin`, or with nothing to aim at
-- for long enough, back toward straight ahead. Returns whether it now points at `aim_point` closely enough to fire.
local function turn(
	entity: Entity,
	index: number,
	turret: types.Turret,
	origin: Vector3,
	aim_point: Vector3?,
	delta: number
): boolean
	local aim = entity.weapon_aims[index] or 0
	local idle = idle_for[entity.id]
	if idle == nil then
		idle = {}
		idle_for[entity.id] = idle
	end

	local desired = aim
	if aim_point ~= nil then
		idle[index] = 0
		local dx, dz = aim_point.X - origin.X, aim_point.Z - origin.Z
		-- straight overhead is every way at once, so it is wherever the turret already points
		if dx * dx + dz * dz > 1e-6 then
			desired = geometry.wrap_angle(math.atan2(dx, dz) - entity.facing)
		end
	else
		local waited = (idle[index] or 0) + delta
		idle[index] = waited
		if waited >= TURRET_REST_DELAY then
			desired = 0
		end
	end

	local off = geometry.wrap_angle(desired - aim)
	local step = turret.turn_rate * delta
	if math.abs(off) <= step then
		aim = desired
	else
		aim = geometry.wrap_angle(aim + if off > 0 then step else -step)
	end
	entity.weapon_aims[index] = aim

	return aim_point ~= nil and math.abs(geometry.wrap_angle(desired - aim)) <= TURRET_TOLERANCE
end

local function forget(id: EntityId)
	idle_for[id] = nil
end

return table.freeze({
	forget = forget,
	turn = turn,
})
