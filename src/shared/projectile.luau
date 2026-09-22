-- The flight of a rocket, shared so that the server, which decides what it hits, and the client, which
-- draws it, fly it exactly the same way without one having to stream the other its position.
--
-- A rocket thrusts along its heading for `thrust_time` seconds, speeding up as it goes. After that it
-- has no push left: drag bleeds its speed away and gravity takes hold, so it loses its momentum and
-- falls.
--
-- A missile flies differently: it climbs straight up, crosses to its target at the height it climbed to, and
-- dives onto it, at one speed the whole way, turning onto each new heading over a moment.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)

type ProjectileParams = types.ProjectileParams

export type Flight = {
	position: Vector3,
	velocity: Vector3,
	-- seconds since launch
	age: number,
	-- what a missile has beyond that: the leg of its flight it is on, where it is going and the height it
	-- crosses at. A rocket that is not a missile has none of them.
	phase: ("climb" | "cruise" | "dive")?,
	target: Vector3?,
	ceiling: number?,
}

-- A rocket is launched along `direction`; a missile ignores it and is launched straight up, toward `aim`.
local function launch(from: Vector3, direction: Vector3, params: ProjectileParams, aim: Vector3?): Flight
	local missile = params.missile
	if missile ~= nil and aim ~= nil then
		return {
			position = from,
			velocity = Vector3.yAxis * params.speed,
			age = 0,
			phase = "climb",
			target = aim,
			ceiling = math.max(from.Y, aim.Y) + missile.climb,
		}
	end
	return {
		position = from,
		velocity = direction.Unit * params.speed,
		age = 0,
	}
end

-- The direction to launch at, how long the flight takes, and the speed to launch at, for a shell with no thrust to land
-- on `to` from `from`. At its full speed a shell has only two angles that reach a target, the low one and the high
-- one, and `params.arc` picks between them. The medium arc is the angle halfway between the two, which at full
-- speed would carry the shell past the target, so it is launched slower, at just the speed that lands it there. A
-- target too far for the shell's speed gets the angle that carries it furthest, at full speed, instead.
local function aim(from: Vector3, to: Vector3, params: ProjectileParams): (Vector3, number, number)
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local distance = flat.Magnitude
	local speed = params.speed
	local gravity = params.gravity
	if distance < 1e-3 then
		return Vector3.yAxis, 2 * speed / gravity, speed
	end

	local rise = to.Y - from.Y
	local discriminant = speed ^ 4 - gravity * (gravity * distance * distance + 2 * rise * speed * speed)
	local slope: number
	if discriminant < 0 then
		slope = speed * speed / (gravity * distance)
	else
		local root = math.sqrt(discriminant)
		local low = (speed * speed - root) / (gravity * distance)
		local high = (speed * speed + root) / (gravity * distance)
		if params.arc == "high" then
			slope = high
		elseif params.arc == "medium" then
			slope = math.tan((math.atan(low) + math.atan(high)) / 2)
			-- the speed that lands a shell launched at this angle on the target: d = v cos(a) t and
			-- rise = v sin(a) t - g t^2 / 2 solve to v^2 = g d^2 (1 + slope^2) / (2 (d slope - rise))
			local reaching = distance * slope - rise
			if reaching > 1e-6 then
				speed = math.min(speed, math.sqrt(gravity * distance * distance * (1 + slope * slope) / (2 * reaching)))
			end
		else
			slope = low
		end
	end

	local direction = (flat.Unit + Vector3.yAxis * slope).Unit
	local horizontal_speed = speed / math.sqrt(1 + slope * slope)
	return direction, distance / horizontal_speed, speed
end

-- How long a rocket that goes straight takes to cover `distance`, from launch: it speeds up for `thrust_time`,
-- and after that is taken to go on at the speed it had reached, which is close enough for what a weapon reaches.
-- This is what aiming ahead of a moving target needs.
local function time_to_reach(distance: number, params: ProjectileParams): number
	local thrust = params.thrust_time
	local reach_at_end = params.speed * thrust + 0.5 * params.acceleration * thrust * thrust
	if distance > reach_at_end then
		return thrust + (distance - reach_at_end) / (params.speed + params.acceleration * thrust)
	end
	if params.acceleration < 1e-6 then
		return distance / params.speed
	end
	return (math.sqrt(params.speed * params.speed + 2 * params.acceleration * distance) - params.speed)
		/ params.acceleration
end

-- Advances a missile by `delta` seconds, in place. It climbs until it is at its ceiling, crosses toward
-- the target until the target is far enough beneath it that the line down to it is as steep as the missile's
-- dive angle, and from then on flies at the target.
local function step_missile(
	flight: Flight,
	params: ProjectileParams,
	missile: types.Missile,
	target: Vector3,
	delta: number
)
	local position = flight.position
	local desired = Vector3.yAxis
	if flight.phase == "climb" and position.Y >= (flight.ceiling or position.Y) then
		flight.phase = "cruise"
	end
	if flight.phase == "cruise" then
		local across = Vector3.new(target.X - position.X, 0, target.Z - position.Z)
		if across.Magnitude * math.tan(missile.dive_angle) <= position.Y - target.Y then
			flight.phase = "dive"
		else
			desired = if across.Magnitude > 1e-3 then across.Unit else desired
		end
	end
	if flight.phase == "dive" then
		local to_target = target - position
		desired = if to_target.Magnitude > 1e-3 then to_target.Unit else -Vector3.yAxis
	end

	flight.age += delta
	local turned = flight.velocity.Unit:Lerp(desired, math.min(1, config.MISSILE_TURN_RATE * delta))
	flight.velocity = (if turned.Magnitude > 1e-3 then turned.Unit else desired) * params.speed
	flight.position += flight.velocity * delta
end

-- Advances a flight by `delta` seconds, in place.
local function step(flight: Flight, params: ProjectileParams, delta: number)
	local missile = params.missile
	local target = flight.target
	if missile ~= nil and target ~= nil then
		step_missile(flight, params, missile, target, delta)
		return
	end

	flight.age += delta
	if flight.age <= params.thrust_time then
		local speed = flight.velocity.Magnitude
		flight.velocity = flight.velocity.Unit * (speed + params.acceleration * delta)
	else
		local kept = math.max(0, 1 - params.drag * delta)
		flight.velocity = flight.velocity * kept - Vector3.new(0, params.gravity * delta, 0)
	end
	flight.position += flight.velocity * delta
end

-- How far a shell launched at `speed` under `gravity` can land from its launcher, along the ground, when the target is
-- `drop` studs below the launcher (a negative drop is a target above it), from the best angle there is.
local function reach(speed: number, gravity: number, drop: number): number
	local under = speed * speed + 2 * gravity * drop
	if under <= 0 then
		return 0
	end
	return speed / gravity * math.sqrt(under)
end

-- How far `range` reaches when a shell of `params` is fired from `from` at `to`. A weapon's range is what it reaches
-- over level ground; from higher up a shell carries further and at something higher up it falls short, by as much
-- as the arc's own reach changes. Only what arcs is changed by it: a rocket or a beam has its range as it is.
local function range_to(range: number, from: Vector3, to: Vector3, params: ProjectileParams): number
	if params.arc == nil or params.gravity <= 0 then
		return range
	end
	local level = reach(params.speed, params.gravity, 0)
	local here = reach(params.speed, params.gravity, from.Y - to.Y)
	return math.max(0, range + here - level)
end

-- The points a shell with no thrust passes through on its way from `from` to `to`, about `spacing` studs apart along
-- the ground and not counting the last, which is `to` itself. It is the path `aim` sends it along, before any
-- inaccuracy. It is what says whether the ground gets in the way of a shell that arcs.
local function trajectory(from: Vector3, to: Vector3, params: ProjectileParams, spacing: number): { Vector3 }
	local direction, flight_time, speed = aim(from, to, params)
	local velocity = direction * speed
	local flat = Vector2.new(to.X - from.X, to.Z - from.Z).Magnitude
	local count = math.max(1, math.ceil(flat / spacing))
	local points = {}
	for index = 1, count - 1 do
		local t = flight_time * index / count
		table.insert(points, from + velocity * t - Vector3.new(0, 0.5 * params.gravity * t * t, 0))
	end
	return points
end

return table.freeze({
	launch = launch,
	trajectory = trajectory,
	range_to = range_to,
	aim = aim,
	time_to_reach = time_to_reach,
	step = step,
})
