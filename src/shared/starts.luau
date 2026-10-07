--!strict
-- Where each team starts. Every map says where each of its starts ideally is (`Preset.starts`); if one is under water
-- or on a slope it is moved to the nearest ground that is dry and level enough to open on. Like the heightmap it is a
-- pure function of the map, so the server and the client, and the metal spots laid out around each start, all agree
-- without being told.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_types = require(ReplicatedStorage.Shared.map_types)

type Preset = map_types.Preset
type StartBox = map_types.StartBox

-- The start has to be dry, with this much room around it, and this far above the water.
local CLEAR_HALF_EXTENT = 16
local MIN_HEIGHT_ABOVE_WATER = ground_levels.DRY_GROUND_MARGIN
local MAX_SLOPE_STUDS = 4
local SEARCH_STEP = 8
local SEARCH_RADIUS = 240

local centers: { Vector2 } = {}
local boxes: { StartBox } = {}

local function fits(x: number, z: number): boolean
	if
		heightmap.in_bounds(x - CLEAR_HALF_EXTENT, z - CLEAR_HALF_EXTENT) == false
		or heightmap.in_bounds(x + CLEAR_HALF_EXTENT, z + CLEAR_HALF_EXTENT) == false
	then
		return false
	end
	local lowest, highest = heightmap.height_range(x, z, CLEAR_HALF_EXTENT, CLEAR_HALF_EXTENT)
	return lowest >= ground_levels.WATER_LEVEL + MIN_HEIGHT_ABOVE_WATER and highest - lowest <= MAX_SLOPE_STUDS
end

-- The first point `accept` takes, going out from (x, z) in rings SEARCH_STEP apart to SEARCH_RADIUS, or nil if it
-- takes none.
local function search(x: number, z: number, accept: (x: number, z: number) -> boolean): Vector2?
	for radius = 0, SEARCH_RADIUS, SEARCH_STEP do
		local around = math.max(1, math.ceil(math.pi * 2 * radius / SEARCH_STEP))
		for step = 0, around - 1 do
			local angle = step * (math.pi * 2 / around)
			local at_x = x + math.cos(angle) * radius
			local at_z = z + math.sin(angle) * radius
			if accept(at_x, at_z) then
				return Vector2.new(at_x, at_z)
			end
		end
	end
	return nil
end

-- Lays out the starts of `preset`, whose ground the heightmap has to have been built from already (see map_state).
local function initialize(preset: Preset)
	table.clear(centers)
	boxes = preset.start_boxes
	-- on a symmetric map a start's twin is where it would be turned half round, so the ground has to fit at both
	local accept = if preset.symmetric == true
		then function(x: number, z: number): boolean
			return fits(x, z) and fits(-x, -z)
		end
		else fits
	for slot, wanted in preset.starts do
		local twin: Vector2? = nil
		if preset.symmetric == true then
			for earlier = 1, slot - 1 do
				local other = preset.starts[earlier]
				if math.abs(other.X + wanted.X) < 0.5 and math.abs(other.Y + wanted.Y) < 0.5 then
					twin = -centers[earlier]
				end
			end
		end
		if twin ~= nil then
			centers[slot] = twin
			continue
		end
		local found = search(wanted.X, wanted.Y, accept)
		if found == nil then
			warn(`no dry level ground within {SEARCH_RADIUS} studs of start {slot}; it stays where the map puts it`)
		end
		centers[slot] = found or wanted
	end
end

-- How many starts the map has.
local function count(): number
	return #centers
end

-- The centre of a team's start area, as (x, z); more teams than starts share them, round again from the first.
local function center(slot: number): Vector2
	return centers[(slot - 1) % #centers + 1]
end

local function box_count(): number
	return #boxes
end

-- The map's start box `index` (`Preset.start_boxes`), where a team's players choose to start; more teams than boxes
-- share them, round again from the first.
local function box(index: number): StartBox
	return boxes[(index - 1) % #boxes + 1]
end

local function in_box(index: number, x: number, z: number): boolean
	local chosen = box(index)
	return x >= chosen.min.X and x <= chosen.max.X and z >= chosen.min.Y and z <= chosen.max.Y
end

-- Whether a team can start at (x, z): dry, level ground with room round it, as every start is.
local function can_start_at(x: number, z: number): boolean
	return fits(x, z)
end

-- The ground in box `index` nearest (x, z) that a team can start on, or nil if there is none near.
local function nearest_start(index: number, x: number, z: number): Vector2?
	return search(x, z, function(at_x: number, at_z: number): boolean
		return in_box(index, at_x, at_z) and fits(at_x, at_z)
	end)
end

-- Where to start in box `index` for a player who has not chosen: the start nearest its middle that is in it, or the
-- ground nearest its middle that a team can start on, or its middle if there is none.
local function default_spot(index: number): Vector2
	local chosen = box(index)
	local middle = (chosen.min + chosen.max) / 2
	local best: Vector2? = nil
	for _, start in centers do
		if
			in_box(index, start.X, start.Y) and (best == nil or (start - middle).Magnitude < (best - middle).Magnitude)
		then
			best = start
		end
	end
	return best or nearest_start(index, middle.X, middle.Y) or middle
end

return table.freeze({
	initialize = initialize,
	center = center,
	count = count,
	box_count = box_count,
	box = box,
	in_box = in_box,
	can_start_at = can_start_at,
	nearest_start = nearest_start,
	default_spot = default_spot,
})
