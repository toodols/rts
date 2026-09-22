-- Metal spots: the fixed deposits on the map where a metal extractor can be built.
--
-- A spot is not one place but a finite set of positions an extractor may stand in, every one of them
-- on the building grid. For now each spot has exactly one. Placement never goes anywhere else: the
-- cursor picks whichever valid position, over every spot, is closest to where it points.
--
-- Like the heightmap they are generated from the seed by a pure function, so the client rebuilds
-- exactly the spots the server has instead of having them replicated. Each start position gets a
-- few close to home so every team can open on metal, and the rest are scattered across the middle
-- of the map to be fought over. A few more lie on the sea floor, for the same extractor to be built on
-- underwater. Every spot is on ground flat enough to build on.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local starts = require(ReplicatedStorage.Shared.starts)
local map_presets = require(ReplicatedStorage.Shared.map_presets)

type MetalLayer = map_presets.MetalLayer

-- Spots keep this far from the map edge, so an extractor never hangs off it.
local EDGE_MARGIN = 16
-- The footprint that has to be flat, as a half extent, and how much ground height it may span.
local FLAT_HALF_EXTENT = 3
local MAX_SLOPE_STUDS = 2

local HOME_SPOT_COUNT = 3
local HOME_MIN_RADIUS = 20
local HOME_MAX_RADIUS = 36
local HOME_SPACING = 14

local MIDDLE_SPOT_COUNT = 30
local MIDDLE_SPACING = 60
-- The middle spots stay this far from every start position, so they are not anyone's home spots.
local MIDDLE_CLEARANCE = 90

-- Spots on the sea floor come after all the others, so that adding them leaves the rest where they were.
-- The whole footprint has to be at least this far under the surface, so none is at the shore.
local UNDERWATER_SPOT_COUNT = 12
local UNDERWATER_MIN_DEPTH = 3

-- What an extractor's own income is multiplied by. Most spots are ordinary; every few of the middle
-- ones are richer.
local DEFAULT_MULTIPLIER = 2.0
local RICH_MULTIPLIER = 4.0
local RICH_EVERY = 5
-- How far from a spot's position a building counts as standing on it.
local MATCH_RADIUS = 0.5

local MAX_ATTEMPTS = 1000
-- Decorrelates the spot layout from the terrain noise, which is seeded with the same number.
local SEED_OFFSET = 7919

export type Spot = {
	-- where the deposit is drawn
	center: Vector3,
	-- where an extractor on it may be built
	positions: { Vector3 },
	-- scales the income of an extractor built on it
	multiplier: number,
}

local spots: { Spot } = {}

-- The centre of a team's start area, matching where the server spawns its starting force.
local function start_center(slot: number): Vector2
	return starts.center(slot)
end

local function acceptable(x: number, z: number, spacing: number, underwater: boolean): boolean
	local half_x = config.MAP_CELLS_X * config.CELL_STUDS / 2 - EDGE_MARGIN
	local half_z = config.MAP_CELLS_Z * config.CELL_STUDS / 2 - EDGE_MARGIN
	if math.abs(x) > half_x or math.abs(z) > half_z then
		return false
	end

	local lowest, highest = heightmap.height_range(x, z, FLAT_HALF_EXTENT, FLAT_HALF_EXTENT)
	if highest - lowest > MAX_SLOPE_STUDS then
		return false
	end
	if underwater then
		if highest > config.WATER_LEVEL - UNDERWATER_MIN_DEPTH then
			return false
		end
	elseif lowest < config.WATER_LEVEL then
		-- the others are on dry land
		return false
	end

	for _, spot in spots do
		local dx = spot.center.X - x
		local dz = spot.center.Z - z
		if dx * dx + dz * dz < spacing * spacing then
			return false
		end
	end
	return true
end

-- An extractor is a building, so its spot is on the building grid: the centre of one cell.
local SPOT_HALF_EXTENTS = Vector2.new(config.CELL_STUDS / 2, config.CELL_STUDS / 2)

local function add(x: number, z: number, multiplier: number?)
	local snapped_x, snapped_z = geometry.snap_center(x, z, SPOT_HALF_EXTENTS, config.CELL_STUDS)
	local position = heightmap.ground_position(snapped_x, snapped_z)
	table.insert(spots, {
		center = position,
		positions = { position },
		multiplier = multiplier or DEFAULT_MULTIPLIER,
	})
end

-- Whether every start is at least MIDDLE_CLEARANCE from (x, z).
local function clear_of_starts(x: number, z: number): boolean
	for slot = 1, config.START_SLOTS do
		if (Vector2.new(x, z) - start_center(slot)).Magnitude < MIDDLE_CLEARANCE then
			return false
		end
	end
	return true
end

-- A map that is laid out in layers puts each layer's own number of spots on ground at that layer's height, and
-- nowhere else, which keeps them off the ramps between layers.
local function add_layers(random: Random, layers: { MetalLayer })
	local half_x = config.MAP_CELLS_X * config.CELL_STUDS / 2
	local half_z = config.MAP_CELLS_Z * config.CELL_STUDS / 2
	for _, layer in layers do
		local placed = 0
		for _ = 1, MAX_ATTEMPTS do
			if placed >= layer.count then
				break
			end
			local x = random:NextNumber(-half_x, half_x)
			local z = random:NextNumber(-half_z, half_z)
			local height = heightmap.height_at(x, z)
			if
				height >= layer.min_height
				and height <= layer.max_height
				and (layer.clear_of_starts == false or clear_of_starts(x, z))
				and acceptable(x, z, layer.spacing, layer.underwater)
			then
				add(x, z, layer.multiplier)
				placed += 1
			end
		end
		if placed < layer.count then
			warn(`only found room for {placed} of {layer.count} metal spots on {layer.name}`)
		end
	end
end

-- Must be called after `heightmap.initialize`, with the same seed on both sides.
local function initialize(seed: number)
	table.clear(spots)
	starts.initialize()
	local random = Random.new(seed + SEED_OFFSET)

	for slot = 1, config.START_SLOTS do
		local home = start_center(slot)
		local placed = 0
		for _ = 1, MAX_ATTEMPTS do
			if placed >= HOME_SPOT_COUNT then
				break
			end
			local angle = random:NextNumber(0, math.pi * 2)
			local radius = random:NextNumber(HOME_MIN_RADIUS, HOME_MAX_RADIUS)
			local x = home.X + math.cos(angle) * radius
			local z = home.Y + math.sin(angle) * radius
			if acceptable(x, z, HOME_SPACING, false) then
				add(x, z)
				placed += 1
			end
		end
	end

	local layers = map_presets.get(heightmap.get_preset()).metal_layers
	if layers ~= nil then
		add_layers(random, layers)
		return
	end

	local placed = 0
	for _ = 1, MAX_ATTEMPTS do
		if placed >= MIDDLE_SPOT_COUNT then
			break
		end
		local half_x = config.MAP_CELLS_X * config.CELL_STUDS / 2
		local half_z = config.MAP_CELLS_Z * config.CELL_STUDS / 2
		local x = random:NextNumber(-half_x, half_x)
		local z = random:NextNumber(-half_z, half_z)

		local clear = true
		for slot = 1, config.START_SLOTS do
			local home = start_center(slot)
			if (Vector2.new(x, z) - home).Magnitude < MIDDLE_CLEARANCE then
				clear = false
				break
			end
		end
		if clear and acceptable(x, z, MIDDLE_SPACING, false) then
			add(x, z, if placed % RICH_EVERY == RICH_EVERY - 1 then RICH_MULTIPLIER else nil)
			placed += 1
		end
	end

	local wanted = config.START_SLOTS * HOME_SPOT_COUNT + MIDDLE_SPOT_COUNT
	if #spots < wanted then
		warn(`only found room for {#spots} of {wanted} metal spots; the ground is too steep or crowded`)
	end

	-- a map with little or no sea simply has fewer of these, or none, so there is nothing to warn about
	local sunk = 0
	for _ = 1, MAX_ATTEMPTS do
		if sunk >= UNDERWATER_SPOT_COUNT then
			break
		end
		local half_x = config.MAP_CELLS_X * config.CELL_STUDS / 2
		local half_z = config.MAP_CELLS_Z * config.CELL_STUDS / 2
		local x = random:NextNumber(-half_x, half_x)
		local z = random:NextNumber(-half_z, half_z)
		if acceptable(x, z, MIDDLE_SPACING, true) then
			add(x, z)
			sunk += 1
		end
	end
end

-- Every spot. The returned table is shared, so callers must not change it.
local function all(): { Spot }
	return spots
end

-- The valid extractor position closest to (x, z) within `radius` studs, if any, over every spot.
-- Positions `skip` says are taken are passed over, so an extractor locks onto the nearest one that
-- is still free.
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

-- The multiplier of the spot an extractor at `position` stands on, or 1 when it is not on one.
local function multiplier_at(position: Vector3): number
	for _, spot in spots do
		for _, valid in spot.positions do
			if Vector2.new(position.X - valid.X, position.Z - valid.Z).Magnitude <= MATCH_RADIUS then
				return spot.multiplier
			end
		end
	end
	return 1
end

return table.freeze({
	initialize = initialize,
	multiplier_at = multiplier_at,
	all = all,
	nearest = nearest,
})
