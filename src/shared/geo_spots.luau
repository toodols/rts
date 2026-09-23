-- Geothermal vents: the few places on the map where a geothermal powerplant can be built, as metal spots are where an
-- extractor can.
--
-- BAR's maps put their vents where their authors chose, but the pages the maps here were brought over from do not say
-- where that is, so every map has its vents laid out from the seed, like the metal spots of a generated map. They come
-- in pairs, each vent's twin on the opposite side of the middle of the map, so that neither side of a two-team map is
-- favoured: the maps are all laid out that way round, or near enough. They keep off the starts, away from each other
-- and off the metal spots, on dry ground flat enough to build a powerplant on.
--
-- Like the metal spots they are a pure function of the seed and the map, so the client lays out exactly the vents the
-- server has instead of having them replicated. Must be initialised after the metal spots.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local starts = require(ReplicatedStorage.Shared.starts)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)

-- How many twinned pairs of vents a map has.
local PAIR_COUNT = 2
-- Every geothermal building stands on BAR's 5 x 5 footprint, two cells across here, so a vent is where the centre of a
-- building two cells across goes: on a corner of the building grid.
local FOOTPRINT_HALF_EXTENTS = Vector2.new(config.CELL_STUDS, config.CELL_STUDS)
-- Kept this far from the map edge, from every start, from each other, from every metal spot, and from its own twin.
local EDGE_MARGIN = 24
local START_CLEARANCE = 60
local SPACING = 80
local METAL_CLEARANCE = 10
-- Dry by at least this much under the whole footprint.
local MIN_HEIGHT_ABOVE_WATER = 0.5

local MAX_ATTEMPTS = 2000
-- Decorrelates the vents from the terrain noise and the metal spots, which are seeded with the same number.
local SEED_OFFSET = 104729
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

local function acceptable(x: number, z: number): boolean
	local half_x, half_z = heightmap.half_extents()
	if math.abs(x) > half_x - EDGE_MARGIN or math.abs(z) > half_z - EDGE_MARGIN then
		return false
	end
	local lowest, highest = heightmap.height_range(x, z, FOOTPRINT_HALF_EXTENTS.X, FOOTPRINT_HALF_EXTENTS.Y)
	if highest - lowest > config.MAX_BUILD_SLOPE_STUDS or lowest < config.WATER_LEVEL + MIN_HEIGHT_ABOVE_WATER then
		return false
	end
	local here = Vector2.new(x, z)
	for slot = 1, config.START_SLOTS do
		if (here - starts.center(slot)).Magnitude < START_CLEARANCE then
			return false
		end
	end
	for _, spot in spots do
		if (here - Vector2.new(spot.center.X, spot.center.Z)).Magnitude < SPACING then
			return false
		end
	end
	for _, spot in metal_spots.all() do
		if (here - Vector2.new(spot.center.X, spot.center.Z)).Magnitude < METAL_CLEARANCE then
			return false
		end
	end
	return true
end

local function add(x: number, z: number)
	local position = heightmap.ground_position(x, z)
	table.insert(spots, { center = position, positions = { position } })
end

-- Must be called after `metal_spots.initialize`, with the same seed on both sides.
local function initialize(seed: number)
	table.clear(spots)
	local random = Random.new(seed + SEED_OFFSET)
	local half_x, half_z = heightmap.half_extents()
	local pairs_placed = 0
	for _ = 1, MAX_ATTEMPTS do
		if pairs_placed >= PAIR_COUNT then
			break
		end
		-- the grid is laid out symmetrically about the middle, so a snapped point's twin is snapped too
		local x, z = snapped(random:NextNumber(-half_x, half_x), random:NextNumber(-half_z, half_z))
		if Vector2.new(x, z).Magnitude * 2 < SPACING then
			continue
		end
		if acceptable(x, z) == false or acceptable(-x, -z) == false then
			continue
		end
		add(x, z)
		add(-x, -z)
		pairs_placed += 1
	end
	if pairs_placed < PAIR_COUNT then
		warn(`only found room for {pairs_placed} of {PAIR_COUNT} pairs of geothermal vents`)
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
