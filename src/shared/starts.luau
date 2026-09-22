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

return table.freeze({
	initialize = initialize,
	center = center,
})
