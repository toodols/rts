-- What the designed maps (see init.luau) are drawn with: shapes of ground, the symmetries that keep them fair, and a
-- random stream of their own, so that everything laid out on them is the same on the server, on every client and in
-- the lobby's picture of them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)

type StartBox = map_types.StartBox
type FixedMetalSpot = map_types.FixedMetalSpot

-- What a rich spot is worth, as metal_spots' own rich spots are; an ordinary one is left nil for the ordinary amount.
local RICH = 4.0

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

-- Metal spots at `ordinary` and rich ones at `rich`.
local function spots(ordinary: { Vector2 }, rich: { Vector2 }?): { FixedMetalSpot }
	local out: { FixedMetalSpot } = {}
	for _, at in ordinary do
		table.insert(out, { position = at, multiplier = nil })
	end
	if rich ~= nil then
		for _, at in rich do
			table.insert(out, { position = at, multiplier = RICH })
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
	RICH = RICH,
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
