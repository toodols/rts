-- Hovering aircraft on the move round what they are at. A builder that hovers, working on something, and a gunship,
-- shooting at something, do not stop dead once it is in reach: each keeps a spot in a ring about it, and every few
-- seconds picks a new one near where it is. Of the spots it could pick it takes the one furthest from the spots the
-- others round the same thing hold, so a crowd spreads out a little with every pick: a hundred builders on one
-- blueprint settle, in time, into a ring round it instead of a heap over it. A gunship's new spot is always some way
-- on round the ring, the same way each time, so it keeps circling what it shoots at.
--
-- `orders` asks for the spot every tick an aircraft has its work or its target in reach, and `movement` flies it
-- there. A spot is kept relative to what it is round, so it follows something that moves.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local rng = require(script.Parent.rng)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type EntityDef = types.EntityDef
type EntityId = types.EntityId

-- A builder, which drifts a little either way round, or a gunship, which keeps circling
export type Role = "build" | "gunship"

type Station = {
	target_id: EntityId,
	-- where it is in the ring: which way from the middle, in radians about the up axis, and how far out
	angle: number,
	radius: number,
	-- seconds until it picks again
	remaining: number,
	-- which way round a gunship circles, 1 or -1
	turn: number,
	-- the tick it was last asked for, to let go of one that is no longer wanted
	seen: number,
}

-- How far either way round a builder's next spot may be from where it is.
local BUILD_WINDOW = math.rad(50)
-- How far on round the ring a gunship's next spot is.
local GUNSHIP_STEP_MIN = math.rad(25)
local GUNSHIP_STEP_MAX = math.rad(70)
-- How near its spot a gunship has to be to count as there, in studs: well before it would slow to a stop on it.
local GUNSHIP_ARRIVED = 4
-- A builder picks a new spot every ORBIT_BUILD_REPICK seconds or so, and a gunship every ORBIT_GUNSHIP_REPICK, each
-- give or take ORBIT_REPICK_JITTER of that. The ring runs from ORBIT_INNER to ORBIT_OUTER of how far it reaches, and
-- each pick is the best of ORBIT_CANDIDATES spots.
local ORBIT_BUILD_REPICK = 4
local ORBIT_GUNSHIP_REPICK = 2
local ORBIT_REPICK_JITTER = 0.5
local ORBIT_INNER = 0.55
local ORBIT_OUTER = 0.8
local ORBIT_CANDIDATES = 10

local stations: { [EntityId]: Station } = {}
-- who holds a spot round each thing
local round: { [EntityId]: { [EntityId]: true } } = {}
local tick_count = 0

-- Whether something of `def` keeps a spot in a ring, rather than stopping in reach: an aircraft that hovers. One on
-- wings circles anyway, and a drone stays with its carrier.
local function orbits(def: EntityDef): boolean
	local aircraft = def.air
	return aircraft ~= nil and aircraft.wings == nil and unit_defs.is_drone(def) == false
end

local function forget(entity_id: EntityId)
	local station = stations[entity_id]
	if station == nil then
		return
	end
	stations[entity_id] = nil
	local holders = round[station.target_id]
	if holders ~= nil then
		holders[entity_id] = nil
		if next(holders) == nil then
			round[station.target_id] = nil
		end
	end
end

-- Lets go of every spot nobody asked for last tick: its holder has finished, or gone on to something else.
local function begin_tick()
	tick_count += 1
	for entity_id, station in stations do
		if station.seen < tick_count - 1 then
			forget(entity_id)
		end
	end
end

local function offset_of(angle: number, radius: number): Vector3
	return Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
end

-- How far a spot at `offset` round `target_id` is from the nearest spot anyone else holds round it.
local function room_at(entity_id: EntityId, target_id: EntityId, offset: Vector3): number
	local nearest = math.huge
	local holders = round[target_id]
	if holders == nil then
		return nearest
	end
	for other_id in holders do
		if other_id ~= entity_id then
			local other = stations[other_id]
			nearest = math.min(nearest, (offset_of(other.angle, other.radius) - offset).Magnitude)
		end
	end
	return nearest
end

-- Moves `station` to the roomiest of a handful of spots near `angle`, between `inner` and `outer` from the middle.
local function pick(entity_id: EntityId, station: Station, role: Role, angle: number, inner: number, outer: number)
	local best_room = -math.huge
	for _ = 1, ORBIT_CANDIDATES do
		local candidate_angle = if role == "gunship"
			then angle + station.turn * rng.stream("orbits"):NextNumber(GUNSHIP_STEP_MIN, GUNSHIP_STEP_MAX)
			else angle + rng.stream("orbits"):NextNumber(-BUILD_WINDOW, BUILD_WINDOW)
		-- evenly over the ring's area, not bunched at its inner edge
		local candidate_radius = math.sqrt(rng.stream("orbits"):NextNumber(inner * inner, outer * outer))
		local room = room_at(entity_id, station.target_id, offset_of(candidate_angle, candidate_radius))
		if room > best_room then
			best_room = room
			station.angle = candidate_angle
			station.radius = candidate_radius
		end
	end
end

-- Where `entity` should be this tick while it is at `target` as a `role`: its spot in the ring round it, from `inner`
-- to `outer` studs from its middle, which it moves every few seconds. `delta` is the tick's length.
local function station_point(
	entity: Entity,
	target: Entity,
	role: Role,
	inner: number,
	outer: number,
	delta: number
): Vector3
	local station = stations[entity.id]
	if station ~= nil and station.target_id ~= target.id then
		forget(entity.id)
		station = nil
	end
	local away = entity.position - target.position
	local angle = math.atan2(away.Z, away.X)
	if station == nil then
		local new_station: Station = {
			target_id = target.id,
			angle = angle,
			radius = math.clamp(Vector3.new(away.X, 0, away.Z).Magnitude, inner, outer),
			remaining = 0,
			turn = if rng.stream("orbits"):NextNumber() < 0.5 then -1 else 1,
			seen = tick_count,
		}
		station = new_station
		stations[entity.id] = new_station
		local holders = round[target.id]
		if holders == nil then
			holders = {}
			round[target.id] = holders
		end
		holders[entity.id] = true
	end
	local held = station :: Station
	held.seen = tick_count
	held.remaining -= delta
	-- a gunship that has got to its spot goes straight on to the next, so it never hangs still over what it shoots
	if role == "gunship" then
		local spot = target.position + offset_of(held.angle, held.radius)
		if Vector3.new(spot.X - entity.position.X, 0, spot.Z - entity.position.Z).Magnitude <= GUNSHIP_ARRIVED then
			held.remaining = 0
		end
	end
	if held.remaining <= 0 then
		-- a gunship moves on from where it has got to, a builder from where it meant to be
		pick(entity.id, held, role, if role == "gunship" then angle else held.angle, inner, outer)
		local every = if role == "gunship" then ORBIT_GUNSHIP_REPICK else ORBIT_BUILD_REPICK
		held.remaining = every * (1 + rng.stream("orbits"):NextNumber(-ORBIT_REPICK_JITTER, ORBIT_REPICK_JITTER))
	end
	-- the ring can be narrower than it was, for something that reaches less far now
	held.radius = math.clamp(held.radius, inner, outer)
	return target.position + offset_of(held.angle, held.radius)
end

snapshot.keep("orbits", function()
	return { stations = stations, round = round, tick_count = tick_count }
end, function(saved)
	stations = saved.stations
	round = saved.round
	tick_count = saved.tick_count
end)

return table.freeze({
	ORBIT_INNER = ORBIT_INNER,
	ORBIT_OUTER = ORBIT_OUTER,
	forget = forget,
	orbits = orbits,
	station_point = station_point,
	begin_tick = begin_tick,
})
