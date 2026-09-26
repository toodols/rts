--!strict
-- The flight of a rocket, shared so that the server, which decides what it hits, and the client, which
-- draws it, fly it exactly the same way without one having to stream the other its position.
--
-- A rocket thrusts along its heading for `thrust_time` seconds, speeding up as it goes. After that it
-- has no push left: drag bleeds its speed away and gravity takes hold, so it loses its momentum and
-- falls.
--
-- A missile flies differently: it climbs straight up, crosses to its target at the height it climbed to, and
-- dives onto it, at one speed the whole way, turning onto each new heading over a moment.
--
-- So does a torpedo: it runs level under the water, at its target's depth but never nearer the surface than
-- TORPEDO_DEPTH or the sea floor than TORPEDO_CLEARANCE, and one let go above the water drops into it first.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

type ProjectileParams = types.ProjectileParams
type ProjectileDelivery = types.ProjectileDelivery
type Arc = types.Arc

local TORPEDO_DEPTH = 0.6
local TORPEDO_CLEARANCE = 0.3
-- How fast a torpedo drops into the water or changes the depth it runs at, in studs a second.
local TORPEDO_DIVE_SPEED = 8
-- A homing projectile aims this far along the way its target will have gone by the time it gets there, as a fraction
-- of the whole way: BAR's MissileProjectile leads by 0.7. Leading at all is what stops it chasing the tail of something
-- crossing in front of it and flying past; leading by less than all the way leaves it a little behind a target that
-- turns hard at the last moment, so a hit is likely but never certain.
local HOMING_LEAD = 0.7
-- What a homing projectile falls under once its guidance runs out: Spring's map gravity, 130 elmos a second squared.
local UNGUIDED_GRAVITY = 130 / world_scale.ELMOS_PER_STUD
-- A homing projectile with a limited `guidance_time` that comes within this many studs of what it is steering for and
-- then finds itself getting further away has flown past it, and loses its lock: it falls away rather than coming round
-- to try again.
local LOCK_LOSS_RANGE = 6
-- A shot that has flown this long is gone, whatever it hit; a missile, which climbs and crosses the map, only after
-- MISSILE_MAX_AGE.
local MAX_AGE = 30
local MISSILE_MAX_AGE = 120
-- How fast a missile turns onto a new heading, as the fraction of the turn it makes in a second's flight. A faster
-- missile turns faster still, so that it never swings wider than MISSILE_TURN_RADIUS studs: at one rate for all, the
-- Juggernaut's, three times as fast as the rest, came out of its dive late and landed well past what it was fired at.
local MISSILE_TURN_RATE = 6
local MISSILE_TURN_RADIUS = 12.5
-- How fast a homing projectile turns, in radians a second, where its weapon does not say.
local HOMING_TURN_RATE = 4
-- The chance an anti-air missile misses whatever its target does: it is fired to pass just clear of it, and falls away
-- once it has. A homing missile does not otherwise miss something that stays in its reach, so without this every one
-- would be certain to hit.
local HOMING_MISS_CHANCE = 0.1

-- What one shot is launched with beyond what its weapon's delivery says, which is worked out for each shot as it is
-- fired (projectiles.launch) and flown the same by the server and every client: how fast it leaves its launcher, its
-- projectile's `speed` but for a shell on the medium arc, which is launched slower; and for a homing one, how many
-- seconds it is guided for, after which it stops steering and falls as BAR's does at the end of its `flighttime`
-- (nil for one guided as long as it flies), and where it steers for off its target's middle: nothing for most shots,
-- and just clear of its collider for the few that are to miss (HOMING_MISS_CHANCE). A lofted one
-- (`StraightDelivery.loft`) also has the height above its target it steers for at first, and the seconds over which
-- that sinks onto the target.
export type Shot = {
	speed: number,
	guidance_time: number?,
	aim_offset: Vector3?,
	loft_height: number?,
	loft_time: number?,
}

export type Flight = {
	-- the shot it was launched as
	shot: Shot,
	position: Vector3,
	velocity: Vector3,
	-- seconds since launch
	age: number,
	-- what a missile has beyond that: the leg of its flight it is on, where it is going and the height it
	-- crosses at. A rocket that is not a missile has none of them.
	phase: ("climb" | "cruise" | "dive")?,
	target: Vector3?,
	ceiling: number?,
	-- a torpedo's speed through the water, kept apart from its velocity, which also has its rise and fall in it
	speed: number?,
	-- a homing projectile's: the nearest it has come to what it steers for, and whether it has flown past that and lost
	-- its lock (see `home`)
	nearest: number?,
	lost_lock: boolean?,
}

-- A shot of `delivery` is launched along `direction`; a missile ignores it and is launched straight up, toward `aim`.
-- A rocket also keeps `inherited`, the velocity of what let it go, which is how a bomb goes on with its bomber's speed.
local function launch(
	from: Vector3,
	direction: Vector3,
	delivery: ProjectileDelivery,
	shot: Shot,
	aim: Vector3?,
	inherited: Vector3?
): Flight
	if delivery.kind == "missile" and aim ~= nil then
		return {
			shot = shot,
			position = from,
			velocity = Vector3.yAxis * shot.speed,
			age = 0,
			phase = "climb",
			target = aim,
			ceiling = math.max(from.Y, aim.Y) + delivery.climb,
		}
	end
	if delivery.kind == "torpedo" then
		local level = Vector3.new(direction.X, 0, direction.Z)
		return {
			shot = shot,
			position = from,
			velocity = (if level.Magnitude > 1e-3 then level.Unit else Vector3.zAxis) * shot.speed,
			age = 0,
			target = aim,
			speed = shot.speed,
		}
	end
	return {
		shot = shot,
		position = from,
		velocity = direction.Unit * shot.speed + (inherited or Vector3.zero),
		age = 0,
	}
end

-- How many seconds something let go at `from`, moving at `velocity`, takes to fall to `height` under `gravity`, with
-- nothing slowing it. Something already below that height is taken to be there at once.
local function fall_time(from: Vector3, velocity: Vector3, gravity: number, height: number): number
	if gravity <= 0 then
		return math.huge
	end
	local under = velocity.Y * velocity.Y + 2 * gravity * (from.Y - height)
	if under <= 0 then
		return 0
	end
	return math.max(0, (velocity.Y + math.sqrt(under)) / gravity)
end

-- The direction to launch at, how long the flight takes, and the speed to launch at, for a shell with no thrust to land
-- on `to` from `from`. At its full speed a shell has only two angles that reach a target, the low one and the high
-- one, and `arc` picks between them. The medium arc is the angle halfway between the two, which at full
-- speed would carry the shell past the target, so it is launched slower, at just the speed that lands it there. A
-- target too far for the shell's speed gets the angle that carries it furthest, at full speed, instead.
local function aim(from: Vector3, to: Vector3, params: ProjectileParams, arc: Arc): (Vector3, number, number)
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
		if arc == "high" then
			slope = high
		elseif arc == "medium" then
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
	dive_angle: number,
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
		if across.Magnitude * math.tan(dive_angle) <= position.Y - target.Y then
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
	local rate = math.max(MISSILE_TURN_RATE, params.speed / MISSILE_TURN_RADIUS)
	local turned = flight.velocity.Unit:Lerp(desired, math.min(1, rate * delta))
	flight.velocity = (if turned.Magnitude > 1e-3 then turned.Unit else desired) * params.speed
	flight.position += flight.velocity * delta
end

-- Turns a homing projectile's flight toward a target at `target_position` moving at `target_velocity`, for `delta`
-- seconds, the way BAR's missiles steer: it aims HOMING_LEAD of the way ahead of the target, and turns toward that at
-- its weapon's turn rate, a fixed number of radians a second however far off it is, straight onto it once it is within
-- one step's turn. Its speed is left as it was. It steers for its shot's `aim_offset` off the target's middle, if the
-- shot has one. Once the shot's `guidance_time` is up, or it has flown past what it steers for and lost its lock, it no
-- longer steers at all (`step` lets it fall).
local function home(
	flight: Flight,
	params: ProjectileParams,
	target_position: Vector3,
	target_velocity: Vector3,
	delta: number
)
	local shot = flight.shot
	if flight.lost_lock == true or flight.age > (shot.guidance_time or math.huge) then
		return
	end
	local speed = flight.velocity.Magnitude
	if speed < 1e-3 then
		return
	end
	target_position += shot.aim_offset or Vector3.zero
	-- a lofted one steers for a point above the target that sinks onto it as the flight goes (StraightDelivery.loft)
	local loft_height, loft_time = shot.loft_height, shot.loft_time
	if loft_height ~= nil and loft_time ~= nil and loft_time > 0 then
		target_position += Vector3.new(0, loft_height * math.max(0, 1 - flight.age / loft_time), 0)
	end
	local distance = (target_position - flight.position).Magnitude
	local nearest = flight.nearest or math.huge
	if shot.guidance_time ~= nil and nearest <= LOCK_LOSS_RANGE and distance > nearest then
		flight.lost_lock = true
		return
	end
	flight.nearest = math.min(nearest, distance)
	local wanted = target_position + target_velocity * (distance / speed * HOMING_LEAD) - flight.position
	if wanted.Magnitude < 1e-3 then
		return
	end
	wanted = wanted.Unit
	local heading = flight.velocity / speed
	local off = math.acos(math.clamp(heading:Dot(wanted), -1, 1))
	local most = (params.turn_rate or HOMING_TURN_RATE) * delta
	if off <= most then
		flight.velocity = wanted * speed
		return
	end
	local axis = heading:Cross(wanted)
	if axis.Magnitude < 1e-6 then
		-- straight away from it: any way round will do
		axis = heading:Cross(if math.abs(heading.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis)
	end
	-- turned `most` about the axis (Rodrigues' formula), in plain Vector3 arithmetic rather than through a CFrame, whose
	-- 32-bit insides the headless arena (tools/ai_arena) cannot match to the last bit, as it matches a Vector3's
	local k = axis.Unit
	local cos, sin = math.cos(most), math.sin(most)
	local turned = heading * cos + k:Cross(heading) * sin + k * (k:Dot(heading) * (1 - cos))
	flight.velocity = turned * speed
end

-- The depths a torpedo may run at at (x, z), shallowest and deepest. Where the water is too shallow to hold it the
-- two are the same, and the sea floor is above them.
local function torpedo_band(x: number, z: number): (number, number)
	local top = ground_levels.WATER_LEVEL - TORPEDO_DEPTH
	return top, math.min(top, heightmap.height_at(x, z) + TORPEDO_CLEARANCE)
end

-- Whether the water at (x, z) is deep enough for a torpedo to run through.
local function torpedo_runs_at(x: number, z: number): boolean
	return heightmap.height_at(x, z) + TORPEDO_CLEARANCE <= ground_levels.WATER_LEVEL - TORPEDO_DEPTH
end

-- Advances a torpedo by `delta` seconds, in place. It goes where its velocity points along the level, whatever
-- turned it there (it homes by having its velocity turned, as a rocket does), at its own speed, and makes for the
-- depth of what it was aimed at, as far as the water lets it.
local function step_torpedo(flight: Flight, params: ProjectileParams, delta: number)
	flight.age += delta
	local speed = flight.speed or params.speed
	if flight.age <= params.thrust_time then
		speed += params.acceleration * delta
	end
	flight.speed = speed
	local level = Vector3.new(flight.velocity.X, 0, flight.velocity.Z)
	local heading = if level.Magnitude > 1e-3 then level.Unit else Vector3.zAxis
	local moved = flight.position + heading * speed * delta

	local top, bottom = torpedo_band(moved.X, moved.Z)
	local aimed = if flight.target ~= nil then flight.target.Y else moved.Y
	local wanted = math.clamp(aimed, bottom, top)
	local most = TORPEDO_DIVE_SPEED * delta
	local rise = math.clamp(wanted - moved.Y, -most, most)
	flight.position = moved + Vector3.yAxis * rise
	flight.velocity = heading * speed + Vector3.yAxis * (rise / delta)
end

-- Advances a flight of a shot of `delivery` by `delta` seconds, in place.
local function step(flight: Flight, delivery: ProjectileDelivery, delta: number)
	local params = delivery.projectile
	local target = flight.target
	if delivery.kind == "missile" and target ~= nil then
		step_missile(flight, params, delivery.dive_angle, target, delta)
		return
	end
	if delivery.kind == "torpedo" then
		step_torpedo(flight, params, delta)
		return
	end

	flight.age += delta
	if flight.age <= params.thrust_time then
		local speed = flight.velocity.Magnitude
		flight.velocity = flight.velocity.Unit * (speed + params.acceleration * delta)
	else
		-- drag slows it by `drag` times its speed squared, as air does anything fast: hard while it is quick, hardly at
		-- all once it is slow, so it bleeds its speed off over a stretch rather than all at once, and falls nearly
		-- freely, never faster than sqrt(gravity / drag). This is that slowing solved exactly over the step.
		local kept = 1 / (1 + params.drag * flight.velocity.Magnitude * delta)
		flight.velocity = flight.velocity * kept - Vector3.new(0, params.gravity * delta, 0)
	end
	local homes = delivery.kind == "straight" and delivery.guidance == "homes"
	if homes and (flight.lost_lock == true or flight.age > (flight.shot.guidance_time or math.huge)) then
		flight.velocity -= Vector3.new(0, UNGUIDED_GRAVITY * delta, 0)
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

-- How far `range` reaches when a shot of `delivery` is fired from `from` at `to`. A weapon's range is what it reaches
-- over level ground; from higher up a shell carries further and at something higher up it falls short, by as much
-- as the arc's own reach changes. Only what is lobbed is changed by it: a rocket or a beam has its range as it is.
local function range_to(range: number, from: Vector3, to: Vector3, delivery: types.Delivery): number
	if delivery.kind ~= "lobbed" or delivery.projectile.gravity <= 0 then
		return range
	end
	local params = delivery.projectile
	local level = reach(params.speed, params.gravity, 0)
	local here = reach(params.speed, params.gravity, from.Y - to.Y)
	return math.max(0, range + here - level)
end

-- The points a shell with no thrust passes through on its way from `from` to `to`, about `spacing` studs apart along
-- the ground and not counting the last, which is `to` itself. It is the path `aim` sends it along, before any
-- inaccuracy. It is what says whether the ground gets in the way of a shell that arcs.
local function trajectory(from: Vector3, to: Vector3, params: ProjectileParams, arc: Arc, spacing: number): { Vector3 }
	local direction, flight_time, speed = aim(from, to, params, arc)
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

-- The points a lofted missile (StraightDelivery.loft) passes about on its way from `from` to `to`, `spacing` studs
-- apart along the ground and not counting the last. It leaves toward a point `loft` times the distance above `to`,
-- which sinks onto `to` as it goes, so its path is near enough the parabola that leaves along that line and comes
-- down on `to`: `loft` times the distance, times t(1 - t), above the straight line, t going from 0 to 1 along it.
-- It is what says whether the ground gets in the way of one.
local function loft_path(from: Vector3, to: Vector3, loft: number, spacing: number): { Vector3 }
	local distance = (to - from).Magnitude
	local flat = Vector2.new(to.X - from.X, to.Z - from.Z).Magnitude
	local count = math.max(1, math.ceil(flat / spacing))
	local points = {}
	for index = 1, count - 1 do
		local t = index / count
		table.insert(points, from:Lerp(to, t) + Vector3.new(0, loft * distance * t * (1 - t), 0))
	end
	return points
end

-- How long a shot of `delivery` flies at the most before it goes off wherever it is.
local function max_age(delivery: ProjectileDelivery): number
	return if delivery.kind == "missile" then MISSILE_MAX_AGE else MAX_AGE
end

return table.freeze({
	HOMING_MISS_CHANCE = HOMING_MISS_CHANCE,
	launch = launch,
	max_age = max_age,
	fall_time = fall_time,
	trajectory = trajectory,
	loft_path = loft_path,
	range_to = range_to,
	aim = aim,
	time_to_reach = time_to_reach,
	step = step,
	home = home,
	torpedo_runs_at = torpedo_runs_at,
})
