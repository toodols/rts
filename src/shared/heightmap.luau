--!strict
-- The map's ground is a grid of height samples. Cell (cx, cz) spans CELL_STUDS studs and its four
-- corners are grid samples, so world height is a bilinear blend of the four samples around a point.
--
-- Heights are generated from a seed with a pure function, which lets the client rebuild the exact
-- same grid the server has without replicating it. Explosions then edit that grid (`deform`, on the
-- server), and only the edited samples are replicated, as a diff on top of the baseline the client
-- rebuilt (`apply_heights`, `edited_heights`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local craters = require(ReplicatedStorage.Shared.craters)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local world_scale = require(ReplicatedStorage.Shared.world_scale)

local CELL_STUDS = world_scale.CELL_STUDS

-- How big the map is, which is up to its preset (`Preset.size`), so these are set by `initialize` and not constants.
-- Grid samples run 0..cells inclusive, so there is one more sample than cell on each axis. The map is centred on
-- (0, 0), so the origin, its low corner, is half of it back from there. Until a map is built it is none at all.
local map_cells_x = 0
local map_cells_z = 0
local samples_x = map_cells_x + 1
local origin_x = -map_cells_x * CELL_STUDS / 2
local origin_z = -map_cells_z * CELL_STUDS / 2

local heights: { number } = {}
-- The height each edited sample was generated with, by sample index. Only samples that have been edited
-- are here.
local originals: { [number]: number } = {}
local lowest_height = 0
local highest_height = 0
local is_initialized = false

local function sample_index(cx: number, cz: number): number
	return cz * samples_x + cx + 1
end

-- Fills the grid for a map `size` studs across (a preset's, which is a whole number of cells each way), each sample
-- `height_of` its grid point's world position: what a map preset builds from the seed (see map_state.apply).
local function initialize(size: Vector2, height_of: (x: number, z: number) -> number)
	map_cells_x = size.X // CELL_STUDS
	map_cells_z = size.Y // CELL_STUDS
	samples_x = map_cells_x + 1
	origin_x = -map_cells_x * CELL_STUDS / 2
	origin_z = -map_cells_z * CELL_STUDS / 2

	table.clear(heights)
	table.clear(originals)
	lowest_height = math.huge
	highest_height = -math.huge
	for cz = 0, map_cells_z do
		for cx = 0, map_cells_x do
			local height = height_of(origin_x + cx * CELL_STUDS, origin_z + cz * CELL_STUDS)
			heights[sample_index(cx, cz)] = height
			lowest_height = math.min(lowest_height, height)
			highest_height = math.max(highest_height, height)
		end
	end
	is_initialized = true
end

-- How many cells the map is across, along x and then z.
local function cells(): (number, number)
	return map_cells_x, map_cells_z
end

-- How many grid samples are in a row along x, which is what a sample index counts in.
local function samples_across(): number
	return samples_x
end

-- How far the map reaches from its middle, (0, 0), along x and then z, in studs.
local function half_extents(): (number, number)
	return map_cells_x * CELL_STUDS / 2, map_cells_z * CELL_STUDS / 2
end

-- The lowest and highest ground on the map.
local function height_bounds(): (number, number)
	return lowest_height, highest_height
end

local function initialized(): boolean
	return is_initialized
end

-- Height of grid sample (cx, cz), clamped to the edge outside the map.
local function sample(cx: number, cz: number): number
	local clamped_x = math.clamp(cx, 0, map_cells_x)
	local clamped_z = math.clamp(cz, 0, map_cells_z)
	local height = heights[sample_index(clamped_x, clamped_z)]
	if height == nil then
		return ground_levels.TERRAIN_BASE_HEIGHT
	end
	return height
end

local function world_to_grid(x: number, z: number): (number, number)
	return (x - origin_x) / CELL_STUDS, (z - origin_z) / CELL_STUDS
end

local function grid_to_world(cx: number, cz: number): (number, number)
	return origin_x + cx * CELL_STUDS, origin_z + cz * CELL_STUDS
end

local function height_at(x: number, z: number): number
	local gx, gz = world_to_grid(x, z)
	local x0 = math.floor(gx)
	local z0 = math.floor(gz)
	local tx = gx - x0
	local tz = gz - z0

	local h00 = sample(x0, z0)
	local h10 = sample(x0 + 1, z0)
	local h01 = sample(x0, z0 + 1)
	local h11 = sample(x0 + 1, z0 + 1)

	local top = h00 + (h10 - h00) * tx
	local bottom = h01 + (h11 - h01) * tx
	return top + (bottom - top) * tz
end

-- Drops a world position onto the ground.
local function ground_position(x: number, z: number): Vector3
	return Vector3.new(x, height_at(x, z), z)
end

-- How deep the water is over the ground at (x, z): nothing on dry land.
local function water_depth(x: number, z: number): number
	return math.max(0, ground_levels.WATER_LEVEL - height_at(x, z))
end

-- Lowest and highest ground height under an axis-aligned footprint, used to reject building
-- placements on slopes. Samples every grid corner the footprint touches plus its own corners.
local function height_range(center_x: number, center_z: number, half_x: number, half_z: number): (number, number)
	local min_x = center_x - half_x
	local max_x = center_x + half_x
	local min_z = center_z - half_z
	local max_z = center_z + half_z

	local lowest = math.huge
	local highest = -math.huge

	local gx0, gz0 = world_to_grid(min_x, min_z)
	local gx1, gz1 = world_to_grid(max_x, max_z)

	for cz = math.floor(gz0), math.ceil(gz1) do
		for cx = math.floor(gx0), math.ceil(gx1) do
			local wx, wz = grid_to_world(cx, cz)
			-- clamp the sample back into the footprint so corners just outside it do not count
			local height = height_at(math.clamp(wx, min_x, max_x), math.clamp(wz, min_z, max_z))
			lowest = math.min(lowest, height)
			highest = math.max(highest, height)
		end
	end

	return lowest, highest
end

local function in_bounds(x: number, z: number): boolean
	local gx, gz = world_to_grid(x, z)
	return gx >= 0 and gx <= map_cells_x and gz >= 0 and gz <= map_cells_z
end

-- Sets the height of one grid sample. The first time a sample is edited, the height it was generated with
-- is kept: a rim's rise is measured from it, and it marks the sample as one a late client must be sent.
local function write_height(index: number, height: number)
	if originals[index] == nil then
		originals[index] = heights[index]
	end
	heights[index] = height
	highest_height = math.max(highest_height, height)
	lowest_height = math.min(lowest_height, height)
end

-- Sets samples to heights it is told: `changes` is a flat list of sample index, height, sample index, height,
-- and so on. It is how the client takes the server's edits.
local function apply_heights(changes: { number })
	for at = 1, #changes - 1, 2 do
		write_height(changes[at], changes[at + 1])
	end
end

-- Every sample that has ever been edited, as a flat list of sample index and its height now, for a client that
-- has arrived late and missed the edits as they were made.
local function edited_heights(): { number }
	local changes = {}
	for index in originals do
		table.insert(changes, index)
		table.insert(changes, heights[index])
	end
	return changes
end

-- Every edited sample, as a flat list of sample index, the height it was generated with and its height now, by index;
-- and the lowest and highest heights the ground has had. What keeps the game (server/snapshot) keeps the ground as this.
export type KeptEdits = { edits: { number }, lowest: number, highest: number }
local function kept_edits(): KeptEdits
	local indices = {}
	for index in originals do
		table.insert(indices, index)
	end
	table.sort(indices)
	local edits = {}
	for _, index in indices do
		table.insert(edits, index)
		table.insert(edits, originals[index])
		table.insert(edits, heights[index])
	end
	return { edits = edits, lowest = lowest_height, highest = highest_height }
end

-- Puts the ground back as `kept_edits` found it: every sample edited now as it was generated, then every sample edited
-- in `saved` at its height there. Returns the samples that may have moved, as a flat list of sample index and height
-- now, by index, as `deform` does.
local function put_back_edits(saved: KeptEdits): { number }
	local moved: { [number]: boolean } = {}
	for index, original in originals do
		heights[index] = original
		moved[index] = true
	end
	originals = {}
	local edits = saved.edits
	for at = 1, #edits - 2, 3 do
		local index = edits[at]
		originals[index] = edits[at + 1]
		heights[index] = edits[at + 2]
		moved[index] = true
	end
	lowest_height = saved.lowest
	highest_height = saved.highest
	local indices = {}
	for index in moved do
		table.insert(indices, index)
	end
	table.sort(indices)
	local changes = {}
	for _, index in indices do
		table.insert(changes, index)
		table.insert(changes, heights[index])
	end
	return changes
end

-- Presses a crater into the ground: a bowl `depth` studs deep at its centre, rising smoothly to the level
-- of the ground at `radius`, with the ground it pushed aside heaped up in a low rim around it. The samples
-- `is_protected` says are not to be touched keep their heights. Ground can be dug as far down as
-- `craters.DEFORM_FLOOR_HEIGHT`, but is never raised more than `craters.DEFORM_MAX_RISE` above where it was
-- generated. Returns what changed, as a flat list of sample index and new height, and leaves it to the caller
-- to tell the renderer and the clients.
local function deform(
	center_x: number,
	center_z: number,
	radius: number,
	depth: number,
	is_protected: ((x: number, z: number) -> boolean)?
): { number }
	local rim_reach = craters.DEFORM_RIM_REACH
	local reach = radius * rim_reach
	local gx0, gz0 = world_to_grid(center_x - reach, center_z - reach)
	local gx1, gz1 = world_to_grid(center_x + reach, center_z + reach)

	local changes = {}
	for cz = math.max(0, math.ceil(gz0)), math.min(map_cells_z, math.floor(gz1)) do
		for cx = math.max(0, math.ceil(gx0)), math.min(map_cells_x, math.floor(gx1)) do
			local wx, wz = grid_to_world(cx, cz)
			local dx = wx - center_x
			local dz = wz - center_z
			local u = math.sqrt(dx * dx + dz * dz) / radius

			local delta = 0
			if u < 1 then
				local bowl = 1 - u * u
				delta = -depth * bowl * bowl
			elseif u < rim_reach then
				local t = (u - 1) / (rim_reach - 1)
				delta = depth * craters.DEFORM_RIM_FRACTION * math.sin(math.pi * t)
			end
			if delta == 0 or (is_protected ~= nil and is_protected(wx, wz)) then
				continue
			end

			local index = sample_index(cx, cz)
			local current = heights[index]
			local original = if originals[index] ~= nil then originals[index] else current
			local target = current + delta
			if delta > 0 then
				target = math.min(target, math.max(current, original + craters.DEFORM_MAX_RISE))
			else
				target = math.max(target, math.min(current, craters.DEFORM_FLOOR_HEIGHT))
			end
			if target ~= current then
				write_height(index, target)
				table.insert(changes, index)
				table.insert(changes, target)
			end
		end
	end
	return changes
end

-- Where a ray first meets the ground, if it does within `max_distance`. This is worked out from the
-- heightmap alone - nothing in the world is cast against - so it cannot be blocked, missed or changed
-- by anything standing in the way, and the client and server would find the same point.
local RAY_STEP = CELL_STUDS / 2
local RAY_REFINEMENTS = 14

local function ray_to_ground(origin: Vector3, direction: Vector3, max_distance: number): Vector3?
	-- a ray that is not heading down can never come down to the ground from above it
	if direction.Y >= 0 then
		return nil
	end
	local unit = direction.Unit

	local function below_ground(distance: number): boolean
		local point = origin + unit * distance
		return in_bounds(point.X, point.Z) and point.Y <= height_at(point.X, point.Z)
	end

	local behind = 0
	local distance = 0
	while distance <= max_distance do
		if below_ground(distance) then
			-- it crossed the surface between the last step and this one: home in on where
			local near = behind
			local far = distance
			for _ = 1, RAY_REFINEMENTS do
				local middle = (near + far) / 2
				if below_ground(middle) then
					far = middle
				else
					near = middle
				end
			end
			local point = origin + unit * far
			return Vector3.new(point.X, height_at(point.X, point.Z), point.Z)
		end
		behind = distance
		distance += RAY_STEP
	end
	return nil
end

return table.freeze({
	water_depth = water_depth,
	initialize = initialize,
	height_bounds = height_bounds,
	ray_to_ground = ray_to_ground,
	initialized = initialized,
	sample = sample,
	height_at = height_at,
	ground_position = ground_position,
	height_range = height_range,
	world_to_grid = world_to_grid,
	grid_to_world = grid_to_world,
	in_bounds = in_bounds,
	deform = deform,
	apply_heights = apply_heights,
	edited_heights = edited_heights,
	kept_edits = kept_edits,
	put_back_edits = put_back_edits,
	sample_index = sample_index,
	cells = cells,
	samples_across = samples_across,
	half_extents = half_extents,
})
