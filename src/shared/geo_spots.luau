-- Geothermal vents: the few places on a map where a geothermal powerplant can be built, as metal spots are where an
-- extractor can. They are as particular to a map as its metal is, so a map has only the vents it says it has
-- (`Preset.geo_spots`): a BAR map has the ones in its own archive, where BAR has them. A map that has none of its own can
-- ask for one beside every start instead (`Preset.geo_at_starts`), which is laid out from the ground, on the nearest
-- flat, dry place that is off the start itself and off the metal spots. Anything else has no vents at all.
--
-- Like the metal spots they are a pure function of the map, so the client lays out exactly the vents the server has
-- instead of having them replicated. Must be initialised after the metal spots.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local starts = require(ReplicatedStorage.Shared.starts)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local map_presets = require(ReplicatedStorage.Shared.map_presets)

-- Every geothermal building stands on BAR's 5 x 5 footprint, two cells across here, so a vent is where the centre of a
-- building two cells across goes: on a corner of the building grid.
local FOOTPRINT_HALF_EXTENTS = Vector2.new(config.CELL_STUDS, config.CELL_STUDS)
-- A vent beside a start is looked for this far out from the start's centre, nearest first, and keeps this far from the
-- metal spots and from the other vents.
local NEAR_START_MIN = 24
local NEAR_START_MAX = 64
local NEAR_START_STEP = 4
local NEAR_START_ANGLES = 24
local METAL_CLEARANCE = 10
local SPACING = 20
-- Dry by at least this much under the whole footprint.
local MIN_HEIGHT_ABOVE_WATER = 0.5
-- How far from a vent a building may be and still count as standing on it.
local MATCH_RADIUS = 0.5

export type Spot = {
	-- where the vent is drawn
	center: Vector3,
	-- where a building on it may stand
	positions: { Vector3 },
}

local spots: { Spot } = {}

local function snapped(x: number, z: number): (number, number)
	return geometry.snap_center(x, z, FOOTPRINT_HALF_EXTENTS, config.CELL_STUDS)
end

local function add(x: number, z: number)
	local position = heightmap.ground_position(x, z)
	table.insert(spots, { center = position, positions = { position } })
end

-- Whether a geothermal building could stand at (x, z), on the grid already: in bounds, on flat dry ground, and clear of
-- the metal spots and the other vents.
local function fits(x: number, z: number): boolean
	local half = FOOTPRINT_HALF_EXTENTS
	if heightmap.in_bounds(x - half.X, z - half.Y) == false or heightmap.in_bounds(x + half.X, z + half.Y) == false then
		return false
	end
	local lowest, highest = heightmap.height_range(x, z, half.X, half.Y)
	if highest - lowest > config.MAX_BUILD_SLOPE_STUDS or lowest < config.WATER_LEVEL + MIN_HEIGHT_ABOVE_WATER then
		return false
	end
	local here = Vector2.new(x, z)
	for _, spot in metal_spots.all() do
		if (here - Vector2.new(spot.center.X, spot.center.Z)).Magnitude < METAL_CLEARANCE then
			return false
		end
	end
	for _, spot in spots do
		if (here - Vector2.new(spot.center.X, spot.center.Z)).Magnitude < SPACING then
			return false
		end
	end
	return true
end

-- The nearest place a vent fits beside `start`, looking round it first toward the middle of the map.
local function beside(start: Vector2): Vector2?
	local inward = math.atan2(-start.Y, -start.X)
	for radius = NEAR_START_MIN, NEAR_START_MAX, NEAR_START_STEP do
		for step = 0, NEAR_START_ANGLES - 1 do
			-- alternately either side of inward, widening
			local offset = math.ceil(step / 2) * (if step % 2 == 0 then 1 else -1)
			local angle = inward + offset * (math.pi * 2 / NEAR_START_ANGLES)
			local x, z = snapped(start.X + math.cos(angle) * radius, start.Y + math.sin(angle) * radius)
			if fits(x, z) then
				return Vector2.new(x, z)
			end
		end
	end
	return nil
end

-- Must be called after `metal_spots.initialize`, on both sides.
local function initialize(_seed: number)
	table.clear(spots)
	local preset = map_presets.get(heightmap.get_preset())
	if preset.geo_spots ~= nil then
		for _, at in preset.geo_spots do
			add(snapped(at.X, at.Y))
		end
		return
	end
	if preset.geo_at_starts == true then
		for slot = 1, starts.count() do
			local at = beside(starts.center(slot))
			if at ~= nil then
				add(at.X, at.Y)
			else
				warn(`found no room for a geothermal vent beside start {slot}`)
			end
		end
	end
end

-- Every vent. The returned table is shared, so callers must not change it.
local function all(): { Spot }
	return spots
end

-- The valid building position closest to (x, z) within `radius` studs, if any, over every vent. Positions `skip` says
-- are taken are passed over.
local function nearest(x: number, z: number, radius: number, skip: ((position: Vector3) -> boolean)?): Vector3?
	local best: Vector3? = nil
	local best_distance = radius
	for _, spot in spots do
		for _, position in spot.positions do
			if skip ~= nil and skip(position) then
				continue
			end
			local distance = Vector2.new(position.X - x, position.Z - z).Magnitude
			if distance <= best_distance then
				best = position
				best_distance = distance
			end
		end
	end
	return best
end

-- Whether a building at `position` stands on a vent.
local function on_spot(position: Vector3): boolean
	return nearest(position.X, position.Z, MATCH_RADIUS) ~= nil
end

return table.freeze({
	initialize = initialize,
	all = all,
	nearest = nearest,
	on_spot = on_spot,
})
