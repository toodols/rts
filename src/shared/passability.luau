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
-- A hovercraft's classes (HOVER2 and HOVER3, `SLOPE.MODERATE`, 33) hold it to that slope only on land: BAR gives them
-- no limit over water (`maxwaterslope = SLOPE.MAXIMUM`), since a hovercraft rides the water's flat surface and not
-- the sea floor. So a hover class is judged by the surface it rides, the ground or the water over it, whichever is
-- higher, and the sea is flat to it however steep the floor under it.
--
-- A cell is as steep as the average slope of its four corners' surface. Classes with the same limit, and that ride
-- the same surface, share one map, so there are as many maps as there are different pairs of those, not classes.
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
	-- whether it is judged by the water's surface where that is over the ground, as a hovercraft is
	over_water: boolean,
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
	HOVER2 = 33,
	HOVER3 = 33,
}

-- The classes that ride the water's surface, a hovercraft's.
local OVER_WATER_CLASSES: { [string]: boolean } = {
	HOVER2 = true,
	HOVER3 = true,
}

-- Keyed by `map_key`, so classes with the same limit that ride the same surface share.
local maps: { [string]: PassabilityMap } = {}

local function map_key(max_slope: number, over_water: boolean): string
	return if over_water then `{max_slope}w` else `{max_slope}`
end

-- The tangent of the steepest angle a class may stand on, so a cell is judged by its rise over its run and
-- never needs a trigonometric function; nothing is too steep for 90 degrees.
local function steepness_limit(max_slope: number): number
	if max_slope >= 90 then
		return math.huge
	end
	return math.tan(math.rad(max_slope))
end

-- The height of the surface at corner (cx, cz): the ground, or where `over_water` the water over it if that is higher.
local function surface_sample(cx: number, cz: number, over_water: boolean): number
	local ground = heightmap.sample(cx, cz)
	return if over_water then math.max(ground, config.WATER_LEVEL) else ground
end

-- Rise over run of the ground in a cell: the length of the gradient of its surface, averaged over the cell. With
-- `over_water`, of the surface a hovercraft rides instead, the water where it is over the ground.
local function cell_steepness(cx: number, cz: number, over_water: boolean?): number
	local on_water = over_water == true
	local h00 = surface_sample(cx, cz, on_water)
	local h10 = surface_sample(cx + 1, cz, on_water)
	local h01 = surface_sample(cx, cz + 1, on_water)
	local h11 = surface_sample(cx + 1, cz + 1, on_water)
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
	for _, map in maps do
		local limit = steepness_limit(map.max_slope)
		local over_water = map.over_water
		for cz = from_z, to_z do
			for cx = from_x, to_x do
				buffer.writeu8(map.cells, cz * width + cx, if cell_steepness(cx, cz, over_water) <= limit then 1 else 0)
			end
		end
	end
end

local function initialize()
	width, depth = heightmap.cells()
	table.clear(maps)
	for slope_class, max_slope in SLOPE_CLASSES do
		local over_water = OVER_WATER_CLASSES[slope_class] == true
		local key = map_key(max_slope, over_water)
		if maps[key] == nil then
			maps[key] = {
				width = width,
				depth = depth,
				max_slope = max_slope,
				over_water = over_water,
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
	local map = maps[map_key(degrees, OVER_WATER_CLASSES[slope_class :: string] == true)]
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
