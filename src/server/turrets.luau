-- What stands between a weapon choosing what to shoot and firing at it: its turret has to turn to face it, and
-- a pop-up has to unfold. Both are simulation state on the entity (`Entity.weapon_aims`, `Entity.animation`), so
-- a shot waits on them exactly, the same way every time; the client only draws what they already are.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)

type Entity = types.Entity
type EntityId = types.EntityId

local TAU = 2 * math.pi

-- Seconds each turret has had nothing to aim at, by entity and weapon, for turning back to face ahead.
local idle_for: { [EntityId]: { [number]: number } } = {}

-- `angle` brought into (-pi, pi].
local function wrap(angle: number): number
	return angle - TAU * math.floor((angle + math.pi) / TAU)
end

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
			desired = wrap(math.atan2(dx, dz) - entity.facing)
		end
	else
		local waited = (idle[index] or 0) + delta
		idle[index] = waited
		if waited >= config.TURRET_REST_DELAY then
			desired = 0
		end
	end

	local off = wrap(desired - aim)
	local step = turret.turn_rate * delta
	if math.abs(off) <= step then
		aim = desired
	else
		aim = wrap(aim + if off > 0 then step else -step)
	end
	entity.weapon_aims[index] = aim

	return aim_point ~= nil and math.abs(wrap(desired - aim)) <= (turret.tolerance or config.TURRET_TOLERANCE)
end

-- Moves `entity`'s animation on by one tick. `wants_open` says whether any of its weapons has something to shoot
-- this tick. Something with no pop-up is always open. Returns whether its weapons may fire.
local function advance(entity: Entity, popup: types.Popup?, wants_open: boolean): boolean
	local animation = entity.animation
	if popup == nil then
		animation.state = "open"
		return true
	end

	animation.ticks += 1
	local current = animation.state
	if current == "closed" then
		if wants_open then
			animation.state = "opening"
			animation.ticks = 0
		end
	elseif current == "opening" then
		if animation.ticks >= popup.open_ticks then
			animation.state = "open"
			animation.ticks = 0
		end
	elseif current == "open" then
		-- in the open state, ticks counts how long it has had nothing to shoot
		if wants_open then
			animation.ticks = 0
		elseif animation.ticks >= popup.linger_ticks then
			animation.state = "closing"
			animation.ticks = 0
		end
	elseif current == "closing" then
		if wants_open then
			-- it turns round partway, and has only as far to open again as it had already folded
			local folded = math.clamp(animation.ticks / math.max(popup.close_ticks, 1), 0, 1)
			animation.state = "opening"
			animation.ticks = math.round((1 - folded) * popup.open_ticks)
		elseif animation.ticks >= popup.close_ticks then
			animation.state = "closed"
			animation.ticks = 0
		end
	end
	return animation.state == "open"
end

local function forget(id: EntityId)
	idle_for[id] = nil
end

return table.freeze({
	turn = turn,
	advance = advance,
	wrap = wrap,
	forget = forget,
})
