-- Which cells of the map each slope class can stand on, worked out from the heightmap once and kept, so that
-- asking is a byte read and not a slope calculation. Pathfinding and steering both read from it.
--
-- The classes and their limits are BAR's, from the `maxslope` of each movement class in
-- gamedata/movedefs.lua, which is the steepest ground angle in degrees a unit of the class can stand on
-- (the engine's own 1.5 multiplier and the file's division by it cancel, so the number in the file is the
-- angle): 54 for bots, the amphibious bot and the commander (`SLOPE.DIFFICULT`), 27 for tanks (`SLOPE.MINIMUM`). Ground exactly
-- at the limit is passable and anything steeper is not, as it is there. A unit with no slope class, like an
-- aircraft or a ship, has no limit.
--
-- A cell is as steep as the average slope of its four corners' surface. Classes with the same limit share
-- one map, so there are as many maps as there are different limits, not classes.
--
-- The map is a `buffer` of one byte a cell, `1` where the class can stand and `0` where it cannot, in rows of
-- `width`: cell (cx, cz), which spans `config.CELL_STUDS` studs and is counted from 0 at the map's low corner,
-- is byte `cz * width + cx`. A pathfinder can read `buffer.readu8` on it directly.
--
-- `initialize` must be called after `heightmap.initialize`, and `refresh` whenever the ground is edited.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

export type PassabilityMap = {
	width: number,
	depth: number,
	-- the steepest angle it lets through, in degrees
	max_slope: number,
	cells: buffer,
}

local CELL_STUDS = config.CELL_STUDS
-- The map's size in cells, taken from the heightmap by `initialize`, since maps are not all the same size.
local width = config.MAP_CELLS_X
local depth = config.MAP_CELLS_Z

-- Movement class to its `maxslope`, in degrees.
local SLOPE_CLASSES: { [string]: number } = {
	COMMANDERBOT = 54,
	BOT2 = 54,
	BOT3 = 54,
	ABOT3 = 54,
	SBOT2 = 54,
	HBOT4 = 54,
	VBOT6 = 54,
	HABOT5 = 54,
	TBOT3 = 90,
	HTBOT6 = 90,
	TANK2 = 27,
	TANK3 = 27,
	HTANK4 = 27,
	MTANK3 = 27,
	ATANK3 = 54,
}

-- Keyed by max slope, so classes with the same limit share.
local maps: { [number]: PassabilityMap } = {}

-- The tangent of the steepest angle a class may stand on, so a cell is judged by its rise over its run and
-- never needs a trigonometric function; nothing is too steep for 90 degrees.
local function steepness_limit(max_slope: number): number
	if max_slope >= 90 then
		return math.huge
	end
	return math.tan(math.rad(max_slope))
end

-- Rise over run of the ground in a cell: the length of the gradient of its surface, averaged over the cell.
local function cell_steepness(cx: number, cz: number): number
	local h00 = heightmap.sample(cx, cz)
	local h10 = heightmap.sample(cx + 1, cz)
	local h01 = heightmap.sample(cx, cz + 1)
	local h11 = heightmap.sample(cx + 1, cz + 1)
	local rise_x = ((h10 + h11) - (h00 + h01)) / (2 * CELL_STUDS)
	local rise_z = ((h01 + h11) - (h00 + h10)) / (2 * CELL_STUDS)
	return math.sqrt(rise_x * rise_x + rise_z * rise_z)
end

-- Works out again the cells from (first_cx, first_cz) to (last_cx, last_cz), inclusive, in every map.
local function refresh(first_cx: number, first_cz: number, last_cx: number, last_cz: number)
	local from_x = math.max(0, first_cx)
	local from_z = math.max(0, first_cz)
	local to_x = math.min(width - 1, last_cx)
	local to_z = math.min(depth - 1, last_cz)
	for max_slope, map in maps do
		local limit = steepness_limit(max_slope)
		for cz = from_z, to_z do
			for cx = from_x, to_x do
				buffer.writeu8(map.cells, cz * width + cx, if cell_steepness(cx, cz) <= limit then 1 else 0)
			end
		end
	end
end

local function initialize()
	width, depth = heightmap.cells()
	table.clear(maps)
	for _, max_slope in SLOPE_CLASSES do
		if maps[max_slope] == nil then
			maps[max_slope] = {
				width = width,
				depth = depth,
				max_slope = max_slope,
				cells = buffer.create(width * depth),
			}
		end
	end
	refresh(0, 0, width - 1, depth - 1)
end

-- The steepest angle, in degrees, that a slope class can stand on; nil for no class, which has no limit.
local function max_slope(slope_class: string?): number?
	if slope_class == nil then
		return nil
	end
	local degrees = SLOPE_CLASSES[slope_class]
	assert(degrees ~= nil, `unknown slope class "{slope_class}"`)
	return degrees
end

-- The passability map of a slope class, for a pathfinder that wants to read it directly; nil for no class,
-- which can stand anywhere.
local function map_for(slope_class: string?): PassabilityMap?
	local degrees = max_slope(slope_class)
	if degrees == nil then
		return nil
	end
	local map = maps[degrees]
	assert(map ~= nil, "passability.initialize has not been called")
	return map
end

-- Whether cell (cx, cz) is ground the class can stand on. Off the map nothing can, unless it has no class.
local function passable_cell(slope_class: string?, cx: number, cz: number): boolean
	local map = map_for(slope_class)
	if map == nil then
		return true
	end
	if cx < 0 or cx >= width or cz < 0 or cz >= depth then
		return false
	end
	return buffer.readu8(map.cells, cz * width + cx) == 1
end

-- Whether the point (x, z) in the world is on ground the class can stand on.
local function passable_at(slope_class: string?, x: number, z: number): boolean
	local gx, gz = heightmap.world_to_grid(x, z)
	return passable_cell(slope_class, math.floor(gx), math.floor(gz))
end

return table.freeze({
	initialize = initialize,
	refresh = refresh,
	cell_steepness = cell_steepness,
	steepness_limit = steepness_limit,
	max_slope = max_slope,
	map_for = map_for,
	passable_cell = passable_cell,
	passable_at = passable_at,
})
