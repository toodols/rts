-- What the maps made for this game (see init.luau) are drawn with: shapes of ground, the symmetries that keep them fair,
-- the ring the generated maps put their starts on, the sea they share, and a random stream of their own, so that
-- everything laid out on them is the same on the server, on every client and in the lobby's picture of them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local world_scale = require(ReplicatedStorage.Shared.world_scale)
local map_types = require(ReplicatedStorage.Shared.map_types)

type StartBox = map_types.StartBox
type FixedMetalSpot = map_types.FixedMetalSpot

-- How big the maps generated from a seed are: 192 cells, 768 studs, a side, three times the 256 the map used to be.
local GENERATED_SIZE = Vector2.new(192 * world_scale.CELL_STUDS, 192 * world_scale.CELL_STUDS)

-- The generated maps put their starts on a ring around the middle, a quarter of the way round from one to the next,
-- so that nobody opens inside anybody else: start 1 east, 2 south, 3 west and 4 north.
local RING_SLOTS = 4
local RING_RADIUS = 210
-- Where there are four boxes on the ring, the second is the one across from the first, so a game of two starts on
-- opposite sides.
local RING_OPPOSITE_FIRST = { 1, 3, 2, 4 }

-- The sea the generated maps stand in: its bed, which every island and coast rises from, deep enough for ships and above
-- the terrain floor; how ragged its coasts are; and the ripple over everything.
local SEA_FLOOR = -14
local COAST_FREQUENCY = 0.03
local RIPPLE = 0.5
local RIPPLE_FREQUENCY = 0.08

local function smoothstep(t: number): number
	local clamped = math.clamp(t, 0, 1)
	return clamped * clamped * (3 - 2 * clamped)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Noise at (x, z), between about -1 and 1, at `frequency` and from its own `offset`, so that two uses do not match.
local function noise(x: number, z: number, frequency: number, offset: number): number
	return math.noise(x * frequency, z * frequency, offset)
end

-- Noise as `noise` gives it, but the same at (x, z) as at (-x, -z), so that ground drawn with it is the same for either
-- side of a map of two sides: the average of the two, scaled back up to about the same spread.
local function twin_noise(x: number, z: number, frequency: number, offset: number): number
	return (noise(x, z, frequency, offset) + noise(-x, -z, frequency, offset)) * 0.7
end

-- Noise the same at (x, z) as at its turns by a quarter, a half and three quarters about the middle, for a map of four
-- sides: the average of the four, scaled back up to about the same spread.
local function quarter_noise(x: number, z: number, frequency: number, offset: number): number
	return (
		noise(x, z, frequency, offset)
		+ noise(-z, x, frequency, offset)
		+ noise(-x, -z, frequency, offset)
		+ noise(z, -x, frequency, offset)
	) * 0.5
end

-- 1 inside `inner` of a centre, 0 beyond `outer`, and easing from one to the other between.
local function falloff(distance: number, inner: number, outer: number): number
	return smoothstep((outer - distance) / (outer - inner))
end

-- A square start box `half` studs out from `center` each way.
local function box_around(center: Vector2, half: number): StartBox
	return { min = center - Vector2.new(half, half), max = center + Vector2.new(half, half) }
end

-- Every point and its twin across the middle of the map, for a map of two sides.
local function twinned(points: { Vector2 }): { Vector2 }
	local out: { Vector2 } = {}
	for _, point in points do
		table.insert(out, point)
		table.insert(out, -point)
	end
	return out
end

-- Every point and its turns by a quarter, a half and three quarters about the middle, for a map of four sides.
local function quartered(points: { Vector2 }): { Vector2 }
	local out: { Vector2 } = {}
	for _, point in points do
		table.insert(out, point)
		table.insert(out, Vector2.new(-point.Y, point.X))
		table.insert(out, -point)
		table.insert(out, Vector2.new(point.Y, -point.X))
	end
	return out
end

-- The angle of the ring's `slot`, in radians about the middle.
local function ring_angle(slot: number): number
	return (slot - 1) * (math.pi * 2 / RING_SLOTS)
end

-- Where the ring's `slot` is, `radius` studs out from the middle.
local function ring_point(slot: number, radius: number): Vector2
	local angle = ring_angle(slot)
	return Vector2.new(math.cos(angle), math.sin(angle)) * radius
end

-- The ring's four starts, `radius` studs out.
-- `build`'s ground made the same turned half round about the middle: the height at (x, z) is the mean of `build`'s
-- there and at (-x, -z), so that what one side has, the side across from it has too.
local function point_symmetric(
	build: (seed: number) -> (x: number, z: number) -> number
): (seed: number) -> (x: number, z: number) -> number
	return function(seed: number): (x: number, z: number) -> number
		local height = build(seed)
		return function(x: number, z: number): number
			return (height(x, z) + height(-x, -z)) / 2
		end
	end
end

local function ring_starts(radius: number): { Vector2 }
	local out: { Vector2 } = {}
	for slot = 1, RING_SLOTS do
		table.insert(out, ring_point(slot, radius))
	end
	return out
end

-- A square around each of the four starts on a ring of `radius`, `half` studs out each way, the opposite one second.
local function ring_boxes(radius: number, half: number): { StartBox }
	local boxes: { StartBox } = {}
	for _, slot in RING_OPPOSITE_FIRST do
		table.insert(boxes, box_around(ring_point(slot, radius), half))
	end
	return boxes
end

-- The sea's ripple at (x, z), laid over all of the ground of a generated map.
local function ripple(x: number, z: number, seed: number): number
	return math.noise(x * RIPPLE_FREQUENCY, z * RIPPLE_FREQUENCY, seed + 3.7) * RIPPLE
end

-- Metal spots at `ordinary` and rich ones at `rich`.
local function spots(ordinary: { Vector2 }, rich: { Vector2 }?): { FixedMetalSpot }
	local out: { FixedMetalSpot } = {}
	for _, at in ordinary do
		table.insert(out, { position = at, multiplier = nil })
	end
	if rich ~= nil then
		for _, at in rich do
			table.insert(out, { position = at, multiplier = map_types.RICH_MULTIPLIER })
		end
	end
	return out
end

-- How far (x, z) is from the segment from `a` to `b`, and how far along it the nearest point is, from 0 at `a` to 1 at
-- `b`.
local function to_segment(x: number, z: number, a: Vector2, b: Vector2): (number, number)
	local dx, dz = b.X - a.X, b.Y - a.Y
	local length_squared = dx * dx + dz * dz
	local t = if length_squared > 0 then math.clamp(((x - a.X) * dx + (z - a.Y) * dz) / length_squared, 0, 1) else 0
	local px, pz = a.X + dx * t, a.Y + dz * t
	return math.sqrt((x - px) ^ 2 + (z - pz) ^ 2), t
end

-- A road: a line of points, each at a height, that the ground is laid level with across its width and eased back into
-- the ground beside it over its bank. Its height runs straight from each point to the next. `low` and `high` are the
-- corners of the box it touches the ground within, bank and all, so that anywhere else it can be passed over at once.
export type Road = {
	points: { Vector3 },
	half_width: number,
	bank: number,
	low: Vector2,
	high: Vector2,
}

-- A road through `points`, as `at` gives them.
local function road(points: { Vector3 }, half_width: number, bank: number): Road
	local reach = half_width + bank
	local low, high = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
	for _, point in points do
		low = Vector2.new(math.min(low.X, point.X - reach), math.min(low.Y, point.Z - reach))
		high = Vector2.new(math.max(high.X, point.X + reach), math.max(high.Y, point.Z + reach))
	end
	return { points = points, half_width = half_width, bank = bank, low = low, high = high }
end

-- Whether (x, z) is in the box from `low` to `high`.
local function within(x: number, z: number, low: Vector2, high: Vector2): boolean
	return x >= low.X and x <= high.X and z >= low.Y and z <= high.Y
end

-- (x, z, height) as a road's point: x and z on the ground, and the height the road is at there.
local function at(x: number, z: number, height: number): Vector3
	return Vector3.new(x, height, z)
end

-- How far (x, z) is from the middle of the road `route`, and its height at the point of it nearest there.
local function to_road(route: Road, x: number, z: number): (number, number)
	local nearest, height = math.huge, 0
	for index = 1, #route.points - 1 do
		local a, b = route.points[index], route.points[index + 1]
		local distance, t = to_segment(x, z, Vector2.new(a.X, a.Z), Vector2.new(b.X, b.Z))
		if distance < nearest then
			nearest = distance
			height = lerp(a.Y, b.Y, t)
		end
	end
	return nearest, height
end

-- `ground` with the road `route` laid over it at (x, z): the road's height on it, the ground beyond its bank, and between
-- the two eased from one to the other.
local function lay_road(route: Road, x: number, z: number, ground: number): number
	if within(x, z, route.low, route.high) == false then
		return ground
	end
	local distance, height = to_road(route, x, z)
	local weight = smoothstep((route.half_width + route.bank - distance) / route.bank)
	return lerp(ground, height, weight)
end

-- Every road's point turned half way round the middle of the map, for the other side of a map of two sides.
local function twin_road(original: Road): Road
	local points: { Vector3 } = {}
	for _, point in original.points do
		table.insert(points, Vector3.new(-point.X, point.Y, -point.Z))
	end
	return road(points, original.half_width, original.bank)
end

-- A stream of numbers from `seed`, the same wherever it is drawn (xorshift, in bit32, which every side has): `next`
-- gives one from 0 up to 1, `range` one from `low` up to `high`.
export type Stream = {
	next: () -> number,
	range: (low: number, high: number) -> number,
}

local function stream(seed: number): Stream
	local value = bit32.bxor(math.floor(math.abs(seed)) % 4294967296, 0x9E3779B9)
	if value == 0 then
		value = 0x2545F491
	end
	local function next(): number
		value = bit32.bxor(value, bit32.lshift(value, 13))
		value = bit32.bxor(value, bit32.rshift(value, 17))
		value = bit32.bxor(value, bit32.lshift(value, 5))
		return value / 4294967296
	end
	return {
		next = next,
		range = function(low: number, high: number): number
			return low + (high - low) * next()
		end,
	}
end

return table.freeze({
	GENERATED_SIZE = GENERATED_SIZE,
	point_symmetric = point_symmetric,
	RING_RADIUS = RING_RADIUS,
	SEA_FLOOR = SEA_FLOOR,
	COAST_FREQUENCY = COAST_FREQUENCY,
	ring_angle = ring_angle,
	ring_point = ring_point,
	ring_starts = ring_starts,
	ring_boxes = ring_boxes,
	ripple = ripple,
	smoothstep = smoothstep,
	lerp = lerp,
	noise = noise,
	twin_noise = twin_noise,
	quarter_noise = quarter_noise,
	falloff = falloff,
	box_around = box_around,
	twinned = twinned,
	quartered = quartered,
	spots = spots,
	to_segment = to_segment,
	at = at,
	road = road,
	within = within,
	to_road = to_road,
	lay_road = lay_road,
	twin_road = twin_road,
	stream = stream,
})
