-- Footprint maths on the ground plane. Buildings are only ever placed on quarter turns, so every
-- footprint stays axis aligned and overlap tests reduce to 2D AABB tests.

local function snap_facing(facing: number): number
	local quarter = math.pi / 2
	return math.round(facing / quarter) * quarter
end

-- Swaps a footprint's axes when it is turned a quarter turn off north.
local function rotated_half_extents(half_extents: Vector2, facing: number): Vector2
	local quarters = math.round(facing / (math.pi / 2)) % 2
	if quarters == 0 then
		return half_extents
	end
	return Vector2.new(half_extents.Y, half_extents.X)
end

local function aabb_overlap(
	a_center: Vector3,
	a_half: Vector2,
	b_center: Vector3,
	b_half: Vector2,
	padding: number
): boolean
	local dx = math.abs(a_center.X - b_center.X)
	local dz = math.abs(a_center.Z - b_center.Z)
	return dx < a_half.X + b_half.X + padding and dz < a_half.Y + b_half.Y + padding
end

local function distance_2d(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

local function flatten(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- Evenly spaced points along a line, the layout used when a right-drag asks a group to spread out.
-- A single unit is placed at the midpoint rather than at one end.
-- Pulls `target` in toward `origin` until it is no further than `range` away on the ground
-- plane. Height is whatever the inputs carried, so callers put the result back on the ground.
local function clamp_to_range(origin: Vector3, target: Vector3, range: number): Vector3
	local offset = flatten(target - origin)
	if offset.Magnitude <= range then
		return target
	end
	return origin + offset.Unit * range
end

-- Snaps a footprint's centre onto the building grid so that its edges land on grid lines: a
-- footprint an odd number of cells across is centred on a cell, an even number across on a line.
-- `half_extents` is the footprint as it will be turned when placed.
local function snap_center(x: number, z: number, half_extents: Vector2, cell: number): (number, number)
	local function snap_axis(value: number, half: number): number
		local cells = math.round(half * 2 / cell)
		if cells % 2 == 1 then
			return math.floor(value / cell) * cell + cell / 2
		end
		return math.round(value / cell) * cell
	end
	return snap_axis(x, half_extents.X), snap_axis(z, half_extents.Y)
end

local function points_along_line(from: Vector3, to: Vector3, count: number): { Vector3 }
	local points = table.create(count)
	if count <= 1 then
		points[1] = from:Lerp(to, 0.5)
		return points
	end
	for index = 1, count do
		points[index] = from:Lerp(to, (index - 1) / (count - 1))
	end
	return points
end

return table.freeze({
	snap_facing = snap_facing,
	rotated_half_extents = rotated_half_extents,
	aabb_overlap = aabb_overlap,
	distance_2d = distance_2d,
	flatten = flatten,
	points_along_line = points_along_line,
	snap_center = snap_center,
	clamp_to_range = clamp_to_range,
})
