-- Where each team starts. Every slot has an ideal place on a ring around the middle of the map; if that
-- is under water or on a slope it is moved to the nearest ground that is dry and level enough to
-- open on. Like the heightmap it is a pure function of the seed, so the server and the client, and the
-- metal spots laid out around each start, all agree without being told.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_presets = require(ReplicatedStorage.Shared.map_presets)

-- The start has to be dry, with this much room around it, and this far above the water.
local CLEAR_HALF_EXTENT = 16
local MIN_HEIGHT_ABOVE_WATER = 1
local MAX_SLOPE_STUDS = 4
local SEARCH_STEP = 8
local SEARCH_RADIUS = 240

local centers: { Vector2 } = {}

local function ideal(slot: number): Vector2
	local start_position = map_presets.get(heightmap.get_preset()).start_position
	if start_position ~= nil then
		return start_position(slot)
	end
	local angle = (slot - 1) * (math.pi * 2 / config.START_SLOTS)
	return Vector2.new(math.cos(angle), math.sin(angle)) * config.START_RING_RADIUS
end

local function fits(x: number, z: number): boolean
	if
		heightmap.in_bounds(x - CLEAR_HALF_EXTENT, z - CLEAR_HALF_EXTENT) == false
		or heightmap.in_bounds(x + CLEAR_HALF_EXTENT, z + CLEAR_HALF_EXTENT) == false
	then
		return false
	end
	local lowest, highest = heightmap.height_range(x, z, CLEAR_HALF_EXTENT, CLEAR_HALF_EXTENT)
	return lowest >= config.WATER_LEVEL + MIN_HEIGHT_ABOVE_WATER and highest - lowest <= MAX_SLOPE_STUDS
end

-- Must be called after `heightmap.initialize`.
local function initialize()
	table.clear(centers)
	for slot = 1, config.START_SLOTS do
		local wanted = ideal(slot)
		local found = wanted
		local placed = false
		for radius = 0, SEARCH_RADIUS, SEARCH_STEP do
			local around = math.max(1, math.ceil(math.pi * 2 * radius / SEARCH_STEP))
			for step = 0, around - 1 do
				local angle = step * (math.pi * 2 / around)
				local x = wanted.X + math.cos(angle) * radius
				local z = wanted.Y + math.sin(angle) * radius
				if fits(x, z) then
					found = Vector2.new(x, z)
					placed = true
					break
				end
			end
			if placed then
				break
			end
		end
		if placed == false then
			warn(`no dry level ground within {SEARCH_RADIUS} studs of start {slot}; it stays where the ring puts it`)
		end
		centers[slot] = found
	end
end

-- The centre of a team's start area, as (x, z).
local function center(slot: number): Vector2
	return centers[(slot - 1) % config.START_SLOTS + 1]
end

-- How many different start points the map has: slots past this are the same places over again.
local function count(): number
	local distinct: { Vector2 } = {}
	for _, point in centers do
		if table.find(distinct, point) == nil then
			table.insert(distinct, point)
		end
	end
	return #distinct
end

-- The map's start boxes (`Preset.start_boxes`), one to a team, where its players choose to start.
local function boxes(): { map_presets.StartBox }
	return map_presets.get(heightmap.get_preset()).start_boxes
end

local function box_count(): number
	return #boxes()
end

-- Start box `index`; more teams than boxes share them, round again from the first.
local function box(index: number): map_presets.StartBox
	local all = boxes()
	return all[(index - 1) % #all + 1]
end

local function in_box(index: number, x: number, z: number): boolean
	local chosen = box(index)
	return x >= chosen.min.X and x <= chosen.max.X and z >= chosen.min.Y and z <= chosen.max.Y
end

-- Whether a team can start at (x, z): dry, level ground with room round it, as every start is.
local function can_start_at(x: number, z: number): boolean
	return fits(x, z)
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
	if best ~= nil then
		return best
	end
	for radius = 0, SEARCH_RADIUS, SEARCH_STEP do
		local around = math.max(1, math.ceil(math.pi * 2 * radius / SEARCH_STEP))
		for step = 0, around - 1 do
			local angle = step * (math.pi * 2 / around)
			local x = middle.X + math.cos(angle) * radius
			local z = middle.Y + math.sin(angle) * radius
			if in_box(index, x, z) and fits(x, z) then
				return Vector2.new(x, z)
			end
		end
	end
	return middle
end

return table.freeze({
	initialize = initialize,
	center = center,
	count = count,
	box_count = box_count,
	box = box,
	in_box = in_box,
	can_start_at = can_start_at,
	default_spot = default_spot,
})
