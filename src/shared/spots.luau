--!strict
-- The spots a building can be bound to (`EntityDef.spot`): the metal spots, the fixed deposits where an extractor can
-- be built, and the geothermal vents, where a geothermal powerplant can. Placement never puts such a building anywhere
-- else: the cursor picks whichever free spot of its kind is closest to where it points, and the building is snapped
-- onto it. The two kinds are placed, snapped and counted as taken in the one way.
--
-- Like the heightmap they are a pure function of the map, so the client lays out exactly the spots the server has
-- instead of having them replicated (see map_state, which lays them out once the heightmap and the starts are).
--
-- Metal: a map that says where its metal is has exactly that (`Preset.metal_spots`). Otherwise each start gets a few
-- close to home so every team can open on metal, and the rest are laid out from the seed, over the map's layers where
-- it has them (`Preset.metal_layers`), or else scattered across the middle of the map to be fought over, with a few
-- more on the sea floor, for the same extractor to be built on underwater. Every spot is on ground flat enough to build
-- on, and each scales the income of the extractor on it (`multiplier_at`).
--
-- Vents are as particular to a map as its metal is, so a map has only the vents it says it has (`Preset.geo_spots`): a
-- BAR map has the ones in its own archive, where BAR has them. A map that has none of its own can ask for one beside
-- every start instead (`Preset.geo_at_starts`), laid out from the ground, on the nearest flat, dry place that is off
-- the start itself and off the metal spots. Anything else has no vents at all.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_types = require(ReplicatedStorage.Shared.map_types)
local starts = require(ReplicatedStorage.Shared.starts)
local types = require(ReplicatedStorage.Shared.types)

type Preset = map_types.Preset
type MetalLayer = map_types.MetalLayer
type SpotKind = types.SpotKind
type EntityDef = types.EntityDef

-- One spot: where what is built on it stands, on the building grid, and what an extractor on it makes, as a multiple
-- of its own income (1 for a vent).
export type Spot = {
	position: Vector3,
	multiplier: number,
}

-- How far from a spot a building may be and still count as standing on it.
local MATCH_RADIUS = 0.5

-- Metal spots keep this far from the map edge, so an extractor never hangs off it; the footprint that has to be flat,
-- as a half extent, and how much ground height it may span.
local EDGE_MARGIN = 16
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
-- Spots on the sea floor come after all the others, so that adding them leaves the rest where they were. The whole
-- footprint has to be at least this far under the surface, so none is at the shore.
local UNDERWATER_SPOT_COUNT = 12
local UNDERWATER_MIN_DEPTH = 3
-- What an extractor's own income is multiplied by on an ordinary spot; every few of the middle ones are rich
-- (map_types.RICH_MULTIPLIER).
local DEFAULT_MULTIPLIER = 2.0
local RICH_EVERY = 5
local MAX_ATTEMPTS = 1000
-- Decorrelates the spot layout from the terrain noise, which is seeded with the same number.
local SEED_OFFSET = 7919
-- An extractor is a building, so its spot is on the building grid: the centre of one cell.
local METAL_HALF_EXTENTS = Vector2.new(world_scale.CELL_STUDS / 2, world_scale.CELL_STUDS / 2)

-- Every geothermal building stands on BAR's 5 x 5 footprint, two cells across here, so a vent is where the centre of a
-- building two cells across goes: on a corner of the building grid.
local VENT_HALF_EXTENTS = Vector2.new(world_scale.CELL_STUDS, world_scale.CELL_STUDS)
-- A vent beside a start is looked for this far out from the start's centre, nearest first, and keeps this far from the
-- metal spots and from the other vents, on ground dry under its whole footprint.
local NEAR_START_MIN = 24
local NEAR_START_MAX = 64
local NEAR_START_STEP = 4
local NEAR_START_ANGLES = 24
local METAL_CLEARANCE = 10
local VENT_SPACING = 20
local VENT_MIN_HEIGHT_ABOVE_WATER = ground_levels.DRY_GROUND_MARGIN

local metal_spots: { Spot } = {}
local vents: { Spot } = {}

-- The spots of `kind`.
local function of_kind(kind: SpotKind): { Spot }
	return if kind == "metal" then metal_spots else vents
end

-- Adds a spot of `kind` on the ground at (x, z), which is on the building grid already.
local function add(kind: SpotKind, x: number, z: number, multiplier: number)
	table.insert(of_kind(kind), { position = heightmap.ground_position(x, z), multiplier = multiplier })
end

-- Adds a metal spot on the building grid cell nearest (x, z).
local function add_metal(x: number, z: number, multiplier: number)
	local snapped_x, snapped_z = geometry.snap_center(x, z, METAL_HALF_EXTENTS, world_scale.CELL_STUDS)
	add("metal", snapped_x, snapped_z, multiplier)
end

-- Whether some spot of `kind` is within `distance` of (x, z).
local function any_within(kind: SpotKind, x: number, z: number, distance: number): boolean
	local here = Vector2.new(x, z)
	for _, spot in of_kind(kind) do
		if (here - Vector2.new(spot.position.X, spot.position.Z)).Magnitude < distance then
			return true
		end
	end
	return false
end

-- Whether every start is at least MIDDLE_CLEARANCE from (x, z).
local function clear_of_starts(x: number, z: number): boolean
	for slot = 1, starts.count() do
		if (Vector2.new(x, z) - starts.center(slot)).Magnitude < MIDDLE_CLEARANCE then
			return false
		end
	end
	return true
end

-- Whether a metal spot may go at (x, z): in from the edge, on flat ground, dry (or deep under the water for an
-- `underwater` one), and `spacing` from every other.
local function metal_fits(x: number, z: number, spacing: number, underwater: boolean): boolean
	local map_half_x, map_half_z = heightmap.half_extents()
	if math.abs(x) > map_half_x - EDGE_MARGIN or math.abs(z) > map_half_z - EDGE_MARGIN then
		return false
	end
	local lowest, highest = heightmap.height_range(x, z, FLAT_HALF_EXTENT, FLAT_HALF_EXTENT)
	if highest - lowest > MAX_SLOPE_STUDS then
		return false
	end
	if underwater then
		if highest > ground_levels.WATER_LEVEL - UNDERWATER_MIN_DEPTH then
			return false
		end
	elseif lowest < ground_levels.WATER_LEVEL then
		return false
	end
	for _, spot in metal_spots do
		local dx = spot.position.X - x
		local dz = spot.position.Z - z
		if dx * dx + dz * dz < spacing * spacing then
			return false
		end
	end
	return true
end

-- A map that is laid out in layers puts each layer's own number of spots on ground at that layer's height, and
-- nowhere else, which keeps them off the ramps between layers.
local function add_layers(random: Random, layers: { MetalLayer })
	local half_x, half_z = heightmap.half_extents()
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
				and metal_fits(x, z, layer.spacing, layer.underwater)
			then
				add_metal(x, z, layer.multiplier or DEFAULT_MULTIPLIER)
				placed += 1
			end
		end
		if placed < layer.count then
			warn(`only found room for {placed} of {layer.count} metal spots on {layer.name}`)
		end
	end
end

local function lay_out_metal(preset: Preset, seed: number)
	-- a map that says where its metal is has exactly that, and nothing laid out from the seed
	local fixed = preset.metal_spots
	if fixed ~= nil then
		for _, spot in fixed do
			add_metal(spot.position.X, spot.position.Y, spot.multiplier or DEFAULT_MULTIPLIER)
		end
		return
	end

	local random = Random.new(seed + SEED_OFFSET)
	for slot = 1, starts.count() do
		local home = starts.center(slot)
		local placed = 0
		for _ = 1, MAX_ATTEMPTS do
			if placed >= HOME_SPOT_COUNT then
				break
			end
			local angle = random:NextNumber(0, math.pi * 2)
			local radius = random:NextNumber(HOME_MIN_RADIUS, HOME_MAX_RADIUS)
			local x = home.X + math.cos(angle) * radius
			local z = home.Y + math.sin(angle) * radius
			if metal_fits(x, z, HOME_SPACING, false) then
				add_metal(x, z, DEFAULT_MULTIPLIER)
				placed += 1
			end
		end
	end

	local layers = preset.metal_layers
	if layers ~= nil then
		add_layers(random, layers)
		return
	end

	local half_x, half_z = heightmap.half_extents()
	local placed = 0
	for _ = 1, MAX_ATTEMPTS do
		if placed >= MIDDLE_SPOT_COUNT then
			break
		end
		local x = random:NextNumber(-half_x, half_x)
		local z = random:NextNumber(-half_z, half_z)
		if clear_of_starts(x, z) and metal_fits(x, z, MIDDLE_SPACING, false) then
			local rich = placed % RICH_EVERY == RICH_EVERY - 1
			add_metal(x, z, if rich then map_types.RICH_MULTIPLIER else DEFAULT_MULTIPLIER)
			placed += 1
		end
	end
	local wanted = starts.count() * HOME_SPOT_COUNT + MIDDLE_SPOT_COUNT
	if #metal_spots < wanted then
		warn(`only found room for {#metal_spots} of {wanted} metal spots; the ground is too steep or crowded`)
	end

	-- a map with little or no sea simply has fewer of these, or none, so there is nothing to warn about
	local sunk = 0
	for _ = 1, MAX_ATTEMPTS do
		if sunk >= UNDERWATER_SPOT_COUNT then
			break
		end
		local x = random:NextNumber(-half_x, half_x)
		local z = random:NextNumber(-half_z, half_z)
		if metal_fits(x, z, MIDDLE_SPACING, true) then
			add_metal(x, z, DEFAULT_MULTIPLIER)
			sunk += 1
		end
	end
end

-- Whether a geothermal building could stand at (x, z), on the grid already: in bounds, on flat dry ground, and clear
-- of the metal spots and the other vents.
local function vent_fits(x: number, z: number): boolean
	local half = VENT_HALF_EXTENTS
	if heightmap.in_bounds(x - half.X, z - half.Y) == false or heightmap.in_bounds(x + half.X, z + half.Y) == false then
		return false
	end
	local lowest, highest = heightmap.height_range(x, z, half.X, half.Y)
	if
		highest - lowest > ground_levels.MAX_BUILD_SLOPE_STUDS
		or lowest < ground_levels.WATER_LEVEL + VENT_MIN_HEIGHT_ABOVE_WATER
	then
		return false
	end
	return any_within("metal", x, z, METAL_CLEARANCE) == false and any_within("geo", x, z, VENT_SPACING) == false
end

-- The nearest place a vent fits beside `start`, looking round it first toward the middle of the map.
local function vent_beside(start: Vector2): Vector2?
	local inward = math.atan2(-start.Y, -start.X)
	for radius = NEAR_START_MIN, NEAR_START_MAX, NEAR_START_STEP do
		for step = 0, NEAR_START_ANGLES - 1 do
			-- alternately either side of inward, widening
			local offset = math.ceil(step / 2) * (if step % 2 == 0 then 1 else -1)
			local angle = inward + offset * (math.pi * 2 / NEAR_START_ANGLES)
			local x, z = geometry.snap_center(
				start.X + math.cos(angle) * radius,
				start.Y + math.sin(angle) * radius,
				VENT_HALF_EXTENTS,
				world_scale.CELL_STUDS
			)
			if vent_fits(x, z) then
				return Vector2.new(x, z)
			end
		end
	end
	return nil
end

local function lay_out_vents(preset: Preset)
	if preset.geo_spots ~= nil then
		for _, at in preset.geo_spots() do
			local x, z = geometry.snap_center(at.X, at.Y, VENT_HALF_EXTENTS, world_scale.CELL_STUDS)
			add("geo", x, z, 1)
		end
		return
	end
	if preset.geo_at_starts == true then
		for slot = 1, starts.count() do
			local at = vent_beside(starts.center(slot))
			if at ~= nil then
				add("geo", at.X, at.Y, 1)
			else
				warn(`found no room for a geothermal vent beside start {slot}`)
			end
		end
	end
end

-- Lays out the spots of `preset` for `seed`, the same on both sides: the metal first, and then the vents, which keep
-- clear of it. The heightmap and the starts have to have been laid out already (see map_state).
local function lay_out(preset: Preset, seed: number)
	table.clear(metal_spots)
	table.clear(vents)
	lay_out_metal(preset, seed)
	lay_out_vents(preset)
end

-- Every spot of `kind`. The returned table is shared, so callers must not change it.
local function all(kind: SpotKind): { Spot }
	return of_kind(kind)
end

-- Where on the spot of `kind` closest to (x, z), within `radius` studs, something may stand, if any is. Spots `skip`
-- says are taken are passed over, so a building locks onto the nearest one that is still free.
local function nearest(
	kind: SpotKind,
	x: number,
	z: number,
	radius: number,
	skip: ((position: Vector3) -> boolean)?
): Vector3?
	local best: Vector3? = nil
	local best_distance = radius
	for _, spot in of_kind(kind) do
		local position = spot.position
		if skip ~= nil and skip(position) then
			continue
		end
		local distance = Vector2.new(position.X - x, position.Z - z).Magnitude
		if distance <= best_distance then
			best = position
			best_distance = distance
		end
	end
	return best
end

-- Whether a building at `position` stands on a spot of `kind`.
local function on_spot(kind: SpotKind, position: Vector3): boolean
	return nearest(kind, position.X, position.Z, MATCH_RADIUS) ~= nil
end

-- The multiplier of the metal spot an extractor at `position` stands on, or 1 when it is not on one.
local function multiplier_at(position: Vector3): number
	for _, spot in metal_spots do
		local at = spot.position
		if Vector2.new(position.X - at.X, position.Z - at.Z).Magnitude <= MATCH_RADIUS then
			return spot.multiplier
		end
	end
	return 1
end

-- Whether `def` is built over something of `other_def_name` in place, which then does not stand in its way.
local function upgrades(def: EntityDef, other_def_name: string): boolean
	return def.upgrades ~= nil and table.find(def.upgrades, other_def_name) ~= nil
end

return table.freeze({
	MATCH_RADIUS = MATCH_RADIUS,
	lay_out = lay_out,
	all = all,
	nearest = nearest,
	on_spot = on_spot,
	multiplier_at = multiplier_at,
	upgrades = upgrades,
})
