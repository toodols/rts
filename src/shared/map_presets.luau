-- Map generation presets. A preset turns the seed into a height function over the whole map, in world
-- coordinates, and the heightmap samples it at every grid point. Each is a pure function of the seed, so
-- the server and the client build the same ground without it being sent.
--
-- highlands: rolling hills with basins that dip below the sea in places, the map as it always was.
-- continents: two continents side by side, joined by two narrow land bridges, with sea all around.
-- islands: islands in an ocean, one under every start, more scattered between, and at least one volcano,
--   a cone far steeper than anything can be built on.
-- koth: a mountain in the sea, in three terraces. The teams start on the lowest and the top is to be held.
-- tutorial: the campaign's first mission, a small valley split by a ridge with one narrow pass through it.
-- overlook: the campaign's second mission, a plateau whose cliff overlooks the low ground, with a ramp down at each end.
-- switchbacks, tidal_flats, boneyard, caldera, mesas, trenches, canyons, gale, last_stand, pinwheel, prairie: maps each
--   drawn to show off one part of the game (see map_designs).
-- supreme_isthmus, hooked, center_command, rifted, comet_catcher, altair_crossing, ancient_bastion, folsom_dam,
--   pinewood_derby, acidic_quarry, aurelia, canis_river, boulder_beach, charlie_in_the_hills, coast_to_coast,
--   devils_postpiles, faster_than_light, gasbag_grabens, great_divide, greenest_fields:
--   Beyond All Reason's maps of those names, from their heightmaps, textures and metal maps (see bar_maps).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local bar_maps = require(ReplicatedStorage.Shared.bar_maps)
local map_types = require(ReplicatedStorage.Shared.map_types)
local map_designs = require(ReplicatedStorage.Shared.map_designs)

type BarMap = bar_maps.BarMap
type Fitted = bar_maps.Fitted

export type MetalLayer = map_types.MetalLayer
export type Theme = map_types.Theme
export type StartBox = map_types.StartBox
export type FixedMetalSpot = map_types.FixedMetalSpot
export type FixedReclaimable = map_types.FixedReclaimable
export type FixedWreck = map_types.FixedWreck
export type Preset = map_types.Preset

-- A square start box `half` studs out from `center` each way.
local function box_around(center: Vector2, half: number): StartBox
	return { min = center - Vector2.new(half, half), max = center + Vector2.new(half, half) }
end

-- Themes ----------------------------------------------------------------------------------------------

local DEFAULT_WATER = Color3.fromRGB(38, 76, 108)

-- Green hills with rocky faces, as the highlands always were, but with grass on them now.
local TEMPERATE: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.LeafyGrass,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Rock,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = nil,
	high_from = nil,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(96, 124, 64),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(82, 110, 58),
		[Enum.Material.Ground] = Color3.fromRGB(110, 94, 70),
		[Enum.Material.Rock] = Color3.fromRGB(104, 100, 94),
	},
	water_color = DEFAULT_WATER,
	paint = nil,
}

-- Beaches and palms: pale sand, bright grass, basalt where it is steep.
local TROPICAL: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.LeafyGrass,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Basalt,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = nil,
	high_from = nil,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(104, 142, 62),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(78, 122, 52),
		[Enum.Material.Sand] = Color3.fromRGB(214, 196, 150),
		[Enum.Material.Basalt] = Color3.fromRGB(62, 58, 58),
	},
	water_color = Color3.fromRGB(34, 96, 118),
	paint = nil,
}

local HALF_X = config.MAP_CELLS_X * config.CELL_STUDS / 2
local HALF_Z = config.MAP_CELLS_Z * config.CELL_STUDS / 2

local function highlands_build(seed: number): (number, number) -> number
	local frequency = config.TERRAIN_FREQUENCY
	local basin_frequency = frequency * config.TERRAIN_BASIN_FREQUENCY_FACTOR
	return function(world_x: number, world_z: number): number
		-- the noise is laid out from the map corner, not its middle
		local x = world_x + HALF_X
		local z = world_z + HALF_Z
		local coarse = math.noise(x * frequency, z * frequency, seed)
		local fine = math.noise(x * frequency * 4, z * frequency * 4, seed + 13.7)
		local basin = math.noise(x * basin_frequency, z * basin_frequency, seed + 29.1)
		return config.TERRAIN_BASE_HEIGHT
			+ (coarse + fine * 0.25) * config.TERRAIN_AMPLITUDE
			+ basin * config.TERRAIN_BASIN_AMPLITUDE
	end
end

-- Islands ---------------------------------------------------------------------------------------------

-- The sea bed, which every island rises from. Deep enough for ships and above the terrain floor.
local SEA_FLOOR = -14
-- How high an ordinary island stands, at its plateau, and how far across it the plateau reaches.
local START_ISLAND_RADIUS = 95
local START_ISLAND_TOP = 7
local PLATEAU_FRACTION = 0.5
local OTHER_ISLAND_COUNT = 6
local OTHER_RADIUS_MIN = 45
local OTHER_RADIUS_MAX = 80
local OTHER_TOP_MIN = 5
local OTHER_TOP_MAX = 9
-- Water kept between any two islands, and between an island and the map edge.
local ISLAND_GAP = 24
local EDGE_MARGIN = 16
-- The volcano: how wide it is at the base, how tall, how sharply it climbs (above 1 it is steeper towards
-- the top), and the crater at its summit. It is on the middle of the map, and now and then another
-- island is one too.
local VOLCANO_RADIUS = 65
local VOLCANO_PEAK = 85
local VOLCANO_SHARPNESS = 1.1
local CRATER_FRACTION = 0.12
local CRATER_DEPTH = 14
local EXTRA_VOLCANO_CHANCE = 0.25
local MAX_ATTEMPTS = 400
-- How ragged the coasts are: the shore distance is scaled by up to this much either way.
local COAST_WARP = 0.22
local COAST_FREQUENCY = 0.03
local RIPPLE = 0.5
local RIPPLE_FREQUENCY = 0.08
-- Decorrelates the layout from the noise, which is seeded with the same number.
local SEED_OFFSET = 4242

type Island = {
	x: number,
	z: number,
	radius: number,
	top: number,
	volcano: boolean,
}

local function smoothstep(t: number): number
	local clamped = math.clamp(t, 0, 1)
	return clamped * clamped * (3 - 2 * clamped)
end

-- Where a team starts, which its island is centred on. The same ring the start module puts them on.
local function ring_position(slot: number): (number, number)
	local angle = (slot - 1) * (math.pi * 2 / config.START_SLOTS)
	return math.cos(angle) * config.START_RING_RADIUS, math.sin(angle) * config.START_RING_RADIUS
end

local function room_for(islands: { Island }, x: number, z: number, radius: number): boolean
	if math.abs(x) > HALF_X - EDGE_MARGIN - radius or math.abs(z) > HALF_Z - EDGE_MARGIN - radius then
		return false
	end
	for _, other in islands do
		local distance = math.sqrt((other.x - x) ^ 2 + (other.z - z) ^ 2)
		if distance < other.radius + radius + ISLAND_GAP then
			return false
		end
	end
	return true
end

local function lay_out_islands(seed: number): { Island }
	local random = Random.new(seed + SEED_OFFSET)
	local islands: { Island } = {}

	-- the volcano first, at the middle, so nothing else takes its place
	table.insert(islands, {
		x = random:NextNumber(-40, 40),
		z = random:NextNumber(-40, 40),
		radius = VOLCANO_RADIUS,
		top = VOLCANO_PEAK,
		volcano = true,
	})

	-- every team has an island of its own, with a flat top to start on
	for slot = 1, config.START_SLOTS do
		local x, z = ring_position(slot)
		table.insert(islands, {
			x = x,
			z = z,
			radius = START_ISLAND_RADIUS,
			top = START_ISLAND_TOP,
			volcano = false,
		})
	end

	local placed = 0
	for _ = 1, MAX_ATTEMPTS do
		if placed >= OTHER_ISLAND_COUNT then
			break
		end
		local volcano = random:NextNumber() < EXTRA_VOLCANO_CHANCE
		local radius = if volcano then VOLCANO_RADIUS else random:NextNumber(OTHER_RADIUS_MIN, OTHER_RADIUS_MAX)
		local x = random:NextNumber(-HALF_X, HALF_X)
		local z = random:NextNumber(-HALF_Z, HALF_Z)
		if room_for(islands, x, z, radius) then
			table.insert(islands, {
				x = x,
				z = z,
				radius = radius,
				top = if volcano
					then random:NextNumber(VOLCANO_PEAK * 0.8, VOLCANO_PEAK)
					else random:NextNumber(OTHER_TOP_MIN, OTHER_TOP_MAX),
				volcano = volcano,
			})
			placed += 1
		end
	end
	if placed < OTHER_ISLAND_COUNT then
		warn(`only found room for {placed} of {OTHER_ISLAND_COUNT} extra islands`)
	end
	return islands
end

-- The height an island gives a point `distance` from its centre.
local function island_height(island: Island, distance: number): number
	local radius = island.radius
	if island.volcano then
		local rim = radius * CRATER_FRACTION
		local function cone(from_centre: number): number
			local t = math.clamp(1 - from_centre / radius, 0, 1)
			return SEA_FLOOR + (island.top - SEA_FLOOR) * t ^ VOLCANO_SHARPNESS
		end
		if distance < rim then
			-- the crater: a bowl sunk into the summit
			local inside = distance / rim
			return cone(rim) - CRATER_DEPTH * (1 - inside * inside)
		end
		return cone(distance)
	end
	-- a flat top that falls away to the sea bed in an S, so the shore slopes gently
	local rise = smoothstep((radius - distance) / (radius * (1 - PLATEAU_FRACTION)))
	return SEA_FLOOR + (island.top - SEA_FLOOR) * rise
end

-- The islands are tropical, and every volcano's crater is still hot.
local function islands_paint(seed: number): (number, number, number, boolean) -> Enum.Material?
	local volcanoes = {}
	for _, island in lay_out_islands(seed) do
		if island.volcano then
			table.insert(volcanoes, island)
		end
	end
	return function(x: number, z: number, height: number, _too_steep: boolean): Enum.Material?
		for _, volcano in volcanoes do
			local distance = math.sqrt((x - volcano.x) ^ 2 + (z - volcano.z) ^ 2)
			if distance < volcano.radius * CRATER_FRACTION then
				return Enum.Material.CrackedLava
			end
			if distance < volcano.radius * 0.6 and height > START_ISLAND_TOP + 4 then
				return Enum.Material.Basalt
			end
		end
		return nil
	end
end

local function islands_build(seed: number): (number, number) -> number
	local islands = lay_out_islands(seed)
	return function(x: number, z: number): number
		local height = SEA_FLOOR
		for index, island in islands do
			local dx = x - island.x
			local dz = z - island.z
			local distance = math.sqrt(dx * dx + dz * dz)
			-- ragged coasts: the same island seen a little nearer or further away from place to place
			local warp = math.noise(x * COAST_FREQUENCY, z * COAST_FREQUENCY, seed + index * 7.31) * COAST_WARP
			height = math.max(height, island_height(island, distance * (1 + warp)))
		end
		return height + math.noise(x * RIPPLE_FREQUENCY, z * RIPPLE_FREQUENCY, seed + 3.7) * RIPPLE
	end
end

-- Continents ------------------------------------------------------------------------------------------

local CONTINENT_CENTER_X = 185
local CONTINENT_HALF_X = 150
local CONTINENT_HALF_Z = 300
local CONTINENT_TOP = 6
-- How much of the way in from the coast the ground takes to reach its full height, as a fraction of the radius.
local CONTINENT_SHORE = 0.35
local CONTINENT_HILLS = 2.5
local CONTINENT_HILL_FREQUENCY = 0.02
-- The bridges run between the continents at these z, each this wide from its middle to one bank.
local BRIDGE_Z = 230
local BRIDGE_HALF_WIDTH = 18
local BRIDGE_TOP = 5
local BRIDGE_BANK = 0.5
local CONTINENT_COAST_WARP = 0.08

-- Teams stand on the far ends of the continents, alternating between the two so that slots 1 and 2, then 3
-- and 4, face each other across the water.
local CONTINENT_START_Z = 110
local CONTINENT_STARTS = {
	Vector2.new(CONTINENT_CENTER_X, -CONTINENT_START_Z),
	Vector2.new(-CONTINENT_CENTER_X, CONTINENT_START_Z),
	Vector2.new(CONTINENT_CENTER_X, CONTINENT_START_Z),
	Vector2.new(-CONTINENT_CENTER_X, -CONTINENT_START_Z),
}

local function continents_build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local warp = 1 + math.noise(x * COAST_FREQUENCY, z * COAST_FREQUENCY, seed + 5.5) * CONTINENT_COAST_WARP
		local dx = (math.abs(x) - CONTINENT_CENTER_X) / CONTINENT_HALF_X
		local dz = z / CONTINENT_HALF_Z
		local land = smoothstep((1 - math.sqrt(dx * dx + dz * dz) * warp) / CONTINENT_SHORE)
		local hills = math.noise(x * CONTINENT_HILL_FREQUENCY, z * CONTINENT_HILL_FREQUENCY, seed + 9.1)
		local height = SEA_FLOOR + (CONTINENT_TOP + hills * CONTINENT_HILLS - SEA_FLOOR) * land

		-- a bridge only exists between the continents
		if math.abs(x) < CONTINENT_CENTER_X then
			local across = math.abs(math.abs(z) - BRIDGE_Z)
			local bridge = smoothstep((BRIDGE_HALF_WIDTH - across) / (BRIDGE_HALF_WIDTH * BRIDGE_BANK))
			height = math.max(height, SEA_FLOOR + (BRIDGE_TOP - SEA_FLOOR) * bridge)
		end
		return height + math.noise(x * RIPPLE_FREQUENCY, z * RIPPLE_FREQUENCY, seed + 3.7) * RIPPLE
	end
end

-- King of the hill ------------------------------------------------------------------------------------

-- Four layers, from the sea up: the sea floor, then three terraces, each a plateau standing on the one below.
-- Every layer is a disc around the middle of the map. Their edges are cliffs, steeper than anything walks or is
-- built on, and the only way up from one to the next is a few narrow ramps, at the angles below.
local KOTH_LAYER_1 = 6
local KOTH_LAYER_2 = 30
local KOTH_LAYER_3 = 54
local KOTH_RADIUS_1 = 350
local KOTH_SHORE = 34
local KOTH_RADIUS_2 = 210
local KOTH_RADIUS_3 = 110
-- How far in from its radius a cliff falls, and so how steep it is: a twenty-four stud drop in five studs.
local KOTH_CLIFF = 5
-- A ramp climbs a layer's height over this length, which is a quarter as steep as it is high, gently enough for a
-- tank, is this wide from its middle to either side, and is banked by the edge width, which is as steep as a cliff.
local KOTH_RAMP_LENGTH = 96
local KOTH_RAMP_HALF_WIDTH = 8
local KOTH_RAMP_EDGE = 6
local KOTH_COAST_WARP = 0.04
-- The teams start on the lowest layer, at the four points of the compass.
local KOTH_START_RADIUS = 265

type Ramp = {
	-- the direction it runs out from the middle, in radians
	angle: number,
	-- the radius of the cliff it climbs
	radius: number,
	lower: number,
	upper: number,
}

-- Between the first and second layers at the diagonals, between the second and third at the other two sides.
local KOTH_RAMPS: { Ramp } = {}
for index = 0, 3 do
	table.insert(KOTH_RAMPS, {
		angle = math.rad(45 + index * 90),
		radius = KOTH_RADIUS_2,
		lower = KOTH_LAYER_1,
		upper = KOTH_LAYER_2,
	})
end
for index = 0, 1 do
	table.insert(KOTH_RAMPS, {
		angle = math.rad(90 + index * 180),
		radius = KOTH_RADIUS_3,
		lower = KOTH_LAYER_2,
		upper = KOTH_LAYER_3,
	})
end

local function koth_build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local distance = math.sqrt(x * x + z * z)
		local warp = 1 + math.noise(x * COAST_FREQUENCY, z * COAST_FREQUENCY, seed + 6.6) * KOTH_COAST_WARP
		local shore = smoothstep((KOTH_RADIUS_1 - distance * warp) / KOTH_SHORE)
		local height = SEA_FLOOR
			+ (KOTH_LAYER_1 - SEA_FLOOR) * shore
			+ (KOTH_LAYER_2 - KOTH_LAYER_1) * smoothstep((KOTH_RADIUS_2 - distance) / KOTH_CLIFF)
			+ (KOTH_LAYER_3 - KOTH_LAYER_2) * smoothstep((KOTH_RADIUS_3 - distance) / KOTH_CLIFF)

		for _, ramp in KOTH_RAMPS do
			local along = x * math.cos(ramp.angle) + z * math.sin(ramp.angle)
			-- 0 at the foot, out on the lower layer, and 1 at the top, where the cliff has finished falling away and the
			-- upper layer begins, so the ramp is a bank built up against the cliff and cuts nothing out of the layer above
			local top = ramp.radius - KOTH_CLIFF
			local climbed = (top + KOTH_RAMP_LENGTH - along) / KOTH_RAMP_LENGTH
			if climbed < 0 or climbed > 1 then
				continue
			end
			local across = math.abs(-x * math.sin(ramp.angle) + z * math.cos(ramp.angle))
			local weight = smoothstep((KOTH_RAMP_HALF_WIDTH + KOTH_RAMP_EDGE - across) / KOTH_RAMP_EDGE)
			height += (ramp.lower + (ramp.upper - ramp.lower) * climbed - height) * weight
		end
		return height + math.noise(x * RIPPLE_FREQUENCY, z * RIPPLE_FREQUENCY, seed + 3.7) * RIPPLE
	end
end

-- Each layer has its own number of extractors. The top holds few and rich ones, and the sea floor round the
-- island has some too. Bands are a little wider than the ripple on the ground, and narrow enough to leave the
-- ramps out.
local KOTH_METAL_LAYERS: { MetalLayer } = {
	{
		name = "sea",
		min_height = SEA_FLOOR - 2,
		max_height = SEA_FLOOR + 2,
		count = 6,
		spacing = 60,
		underwater = true,
		multiplier = nil,
		clear_of_starts = false,
	},
	{
		name = "layer 1",
		min_height = KOTH_LAYER_1 - 1.5,
		max_height = KOTH_LAYER_1 + 1.5,
		count = 10,
		spacing = 60,
		underwater = false,
		multiplier = nil,
		clear_of_starts = true,
	},
	{
		name = "layer 2",
		min_height = KOTH_LAYER_2 - 1.5,
		max_height = KOTH_LAYER_2 + 1.5,
		count = 6,
		spacing = 50,
		underwater = false,
		multiplier = nil,
		clear_of_starts = false,
	},
	{
		name = "layer 3",
		min_height = KOTH_LAYER_3 - 1.5,
		max_height = KOTH_LAYER_3 + 1.5,
		count = 4,
		spacing = 40,
		underwater = false,
		multiplier = 4.0,
		clear_of_starts = false,
	},
}

-- Tutorial --------------------------------------------------------------------------------------------

-- The campaign's first mission (see shared/campaign.luau, whose TUTORIAL has to agree with the numbers here). A small
-- green valley, cut in two from edge to edge by a rocky ridge running north to south, with the player's side to the west
-- and the enemy's to the east. The ridge's faces are cliffs far steeper than anything walks (54 degrees is the most
-- anything can; these are about 80), and the only way through it is one narrow pass across its middle at z = 0, which
-- the tutorial's boulder fills (44 studs across, where the pass floor is 20 and its walls rise to the ridge within 6
-- more each side). Gentle hills rise at the map's edges to frame it. It is all dry: the commander wades any water, so
-- water would be no wall.
local TUTORIAL_SIZE = Vector2.new(320, 208)
local TUTORIAL_GROUND = 4
local TUTORIAL_HILLS = 1.2
local TUTORIAL_HILL_FREQUENCY = 0.025
-- The ridge's top, how far its top reaches either side of x = 0, give or take its warp, and how far out from there its
-- cliff falls to the valley floor.
local TUTORIAL_RIDGE_TOP = 34
local TUTORIAL_RIDGE_HALF = 26
local TUTORIAL_RIDGE_WARP = 4
local TUTORIAL_RIDGE_WARP_FREQUENCY = 0.035
local TUTORIAL_CLIFF = 6
local TUTORIAL_CRAGS = 5
local TUTORIAL_CRAG_FREQUENCY = 0.09
-- The pass: its floor is this far either side of z = 0, and its walls rise to the ridge's top over this much more.
local TUTORIAL_PASS_HALF = 10
local TUTORIAL_PASS_WALL = 6
-- The hills round the edge: how far in from the edge they reach and how high they rise, gently enough to walk up.
local TUTORIAL_RIM_REACH = 22
local TUTORIAL_RIM_TOP = 14
-- The starts, as campaign.TUTORIAL has them.
local TUTORIAL_PLAYER_START = Vector2.new(-110, 0)
local TUTORIAL_ENEMY_START = Vector2.new(110, 0)

local function tutorial_build(seed: number): (number, number) -> number
	local half_x = TUTORIAL_SIZE.X / 2
	local half_z = TUTORIAL_SIZE.Y / 2
	return function(x: number, z: number): number
		local hills = math.noise(x * TUTORIAL_HILL_FREQUENCY, z * TUTORIAL_HILL_FREQUENCY, seed + 2.3) * TUTORIAL_HILLS
		local from_edge = math.min(half_x - math.abs(x), half_z - math.abs(z))
		local rim = smoothstep((TUTORIAL_RIM_REACH - from_edge) / TUTORIAL_RIM_REACH) * TUTORIAL_RIM_TOP
		local floor = TUTORIAL_GROUND + hills + rim

		local warp = math.noise(z * TUTORIAL_RIDGE_WARP_FREQUENCY, 0.5, seed + 8.8) * TUTORIAL_RIDGE_WARP
		local ridge = smoothstep((TUTORIAL_RIDGE_HALF + warp + TUTORIAL_CLIFF - math.abs(x)) / TUTORIAL_CLIFF)
		local pass = smoothstep((math.abs(z) - TUTORIAL_PASS_HALF) / TUTORIAL_PASS_WALL)
		local crags = math.noise(x * TUTORIAL_CRAG_FREQUENCY, z * TUTORIAL_CRAG_FREQUENCY, seed + 4.1) * TUTORIAL_CRAGS
		return floor + (TUTORIAL_RIDGE_TOP + crags - floor) * ridge * pass
	end
end

-- A meadow: bright grass, bare rock on the ridge, and a dirt track through the pass.
local MEADOW: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.LeafyGrass,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Slate,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = Enum.Material.Rock,
	high_from = TUTORIAL_GROUND + TUTORIAL_RIM_TOP + 2,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(110, 150, 70),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(92, 134, 60),
		[Enum.Material.Ground] = Color3.fromRGB(128, 108, 80),
		[Enum.Material.Slate] = Color3.fromRGB(100, 98, 102),
		[Enum.Material.Rock] = Color3.fromRGB(122, 118, 110),
	},
	water_color = DEFAULT_WATER,
	paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
		return function(x: number, z: number, _height: number, too_steep: boolean): Enum.Material?
			local through_pass = math.abs(x) < TUTORIAL_RIDGE_HALF + TUTORIAL_CLIFF + 10
				and math.abs(z) < TUTORIAL_PASS_HALF - 1
			if through_pass and too_steep == false then
				return Enum.Material.Ground
			end
			return nil
		end
	end,
}

-- Every spot has its twin across the middle, so neither side has more.
local TUTORIAL_METAL: { FixedMetalSpot } = {}
for _, at in { Vector2.new(-124, -48), Vector2.new(-124, 48), Vector2.new(-72, -56) } do
	table.insert(TUTORIAL_METAL, { position = at, multiplier = nil })
	table.insert(TUTORIAL_METAL, { position = -at, multiplier = nil })
end

-- A few trees on the hills at the edge and some stones by the mouths of the pass, each with its twin across the middle,
-- holding what their defs say.
local function tutorial_reclaimables(): { FixedReclaimable }
	local laid: { { def_name: string, at: Vector2 } } = {
		{ def_name = "tree", at = Vector2.new(-146, -86) },
		{ def_name = "tree", at = Vector2.new(-134, -92) },
		{ def_name = "tree", at = Vector2.new(-150, -72) },
		{ def_name = "tree", at = Vector2.new(-96, -92) },
		{ def_name = "tree", at = Vector2.new(-148, 84) },
		{ def_name = "tree", at = Vector2.new(-70, 92) },
		{ def_name = "tree", at = Vector2.new(-58, 88) },
		{ def_name = "shrub", at = Vector2.new(-90, 70) },
		{ def_name = "shrub", at = Vector2.new(-150, 20) },
		{ def_name = "small_rock", at = Vector2.new(-46, 26) },
		{ def_name = "small_rock", at = Vector2.new(-52, -24) },
		{ def_name = "rock", at = Vector2.new(-44, -36) },
	}
	local out: { FixedReclaimable } = {}
	for index, each in laid do
		for _, at in { each.at, -each.at } do
			table.insert(out, {
				def_name = each.def_name,
				position = at,
				facing = index * 1.3,
				-- what the defs hold (unit_defs/reclaimable.luau)
				metal = if each.def_name == "small_rock" then 13 elseif each.def_name == "rock" then 21 else 0,
				energy = if each.def_name == "tree" then 250 elseif each.def_name == "shrub" then 50 else 0,
				buildpower = if each.def_name == "small_rock"
					then 78
					elseif each.def_name == "rock" then 126
					elseif each.def_name == "tree" then 1500
					else 300,
			})
		end
	end
	return out
end

-- Overlook ---------------------------------------------------------------------------------------------

-- The campaign's second mission (see shared/campaign.luau, whose OVERLOOK has to agree with the numbers here). The
-- player's side, to the west, is a plateau about OVERLOOK_DROP studs above the low ground to the east, where the enemy's
-- base is. Along most of its length the plateau ends in a cliff, which is what the player looks down on the base from:
-- a shell fired from up there carries further than its range on the level (projectile.range_to), so a thug at the edge
-- outshoots the guards below. Near the north and south edges of the map a ramp, gentle enough for any bot, winds down
-- from the plateau to the low ground between steep sides. Hills rise unevenly at the map's edges to frame it. It is all
-- dry.
--
-- The cliff is drawn so as not to look built: its edge wanders, crags stand out of its face, and its foot runs out into
-- a skirt of scree, while the ground above and below rolls. The face is spread over OVERLOOK_FACE studs, so that it is
-- drawn as a slope of voxels rather than one sheer wall of them, and still far steeper than anything walks (54 degrees
-- is the most anything can; the face is about 75). None of it depends on the seed: the mission's enemy stands where it
-- does against this one cliff.
--
-- It is a small map, 152 by 128 studs: the plateau is some 60 studs deep and the low ground some 90, which is room for
-- the enemy's base behind what a thug at the edge can reach (see server/missions.luau) and not much more. The heights
-- are the weapons' business (a thug outranges a guard from up there by the drop), so they are what they would be on a
-- bigger map; only the lengths across it are small.
local OVERLOOK_SIZE = Vector2.new(152, 128)
local OVERLOOK_GROUND = 4
-- The noise every part of it is drawn from, in place of the seed.
local OVERLOOK_NOISE = 41.7
-- Rolling ground, above and below.
local OVERLOOK_HILLS = 1.5
local OVERLOOK_HILL_FREQUENCY = 0.03
-- The plateau: how far above the low ground it stands, and the x its edge wanders about, by as much as
-- OVERLOOK_EDGE_WANDER one way or the other over long stretches and a little more over short ones.
local OVERLOOK_DROP = 28
local OVERLOOK_EDGE_X = -18
local OVERLOOK_EDGE_WANDER = 3
local OVERLOOK_EDGE_WANDER_FREQUENCY = 0.04
local OVERLOOK_EDGE_JITTER = 1
local OVERLOOK_EDGE_JITTER_FREQUENCY = 0.09
-- The face: how far out from the edge it falls, how much of the drop the scree at its foot takes, over how much more,
-- and the crags, which push the face in and out by as much as OVERLOOK_CRAGS studs.
local OVERLOOK_FACE = 10
local OVERLOOK_SCREE = 0.12
local OVERLOOK_SCREE_RUN = 6
local OVERLOOK_CRAGS = 2
local OVERLOOK_CRAG_FREQUENCY = 0.14
-- The ramps, one each side of z = 0: the middle they wind about, how far either side of it they are a ramp and no
-- less, and how far more their steep sides take to rise to the cliff. Each runs down from the edge over
-- OVERLOOK_RAMP_RUN.
local OVERLOOK_RAMP_Z = 43
local OVERLOOK_RAMP_WIND = 3
local OVERLOOK_RAMP_WIND_FREQUENCY = 0.06
local OVERLOOK_RAMP_HALF = 6
local OVERLOOK_RAMP_SIDE = 5
local OVERLOOK_RAMP_RUN = 40
-- The hills round the edge: how far in from the edge they reach, give or take, and how high they rise, gently enough
-- to walk up.
local OVERLOOK_RIM_REACH = 11
local OVERLOOK_RIM_WANDER = 4
local OVERLOOK_RIM_TOP = 6
-- The starts, as campaign.OVERLOOK has them.
local OVERLOOK_PLAYER_START = Vector2.new(-53, 0)
local OVERLOOK_ENEMY_START = Vector2.new(42, 0)

local function overlook_noise(x: number, z: number, frequency: number, offset: number): number
	return math.noise(x * frequency, z * frequency, OVERLOOK_NOISE + offset)
end

-- The x the plateau's edge is at, at `z`, before the crags.
local function overlook_edge(z: number): number
	return OVERLOOK_EDGE_X
		+ overlook_noise(0.5, z, OVERLOOK_EDGE_WANDER_FREQUENCY, 1.1) * OVERLOOK_EDGE_WANDER * 2
		+ overlook_noise(0.5, z, OVERLOOK_EDGE_JITTER_FREQUENCY, 2.2) * OVERLOOK_EDGE_JITTER * 2
end

-- How much of the way up to the plateau the ground is at (x, z): 1 on it, 0 on the low ground.
local function overlook_plateau(x: number, z: number): number
	local edge = overlook_edge(z) + overlook_noise(x, z, OVERLOOK_CRAG_FREQUENCY, 3.3) * OVERLOOK_CRAGS
	local face = smoothstep((edge + OVERLOOK_FACE - x) / OVERLOOK_FACE)
	local scree = smoothstep((edge + OVERLOOK_FACE + OVERLOOK_SCREE_RUN - x) / (OVERLOOK_FACE + OVERLOOK_SCREE_RUN))
	local cliff = face * (1 - OVERLOOK_SCREE) + scree * OVERLOOK_SCREE

	local ramp = smoothstep((overlook_edge(z) + OVERLOOK_RAMP_RUN - x) / OVERLOOK_RAMP_RUN)
	local middle = OVERLOOK_RAMP_Z + overlook_noise(x, 0.5, OVERLOOK_RAMP_WIND_FREQUENCY, 4.4) * OVERLOOK_RAMP_WIND * 2
	local on_ramp =
		smoothstep((OVERLOOK_RAMP_HALF + OVERLOOK_RAMP_SIDE - math.abs(math.abs(z) - middle)) / OVERLOOK_RAMP_SIDE)
	-- a ramp only ever lifts the ground, so the plateau stays whole behind the edge
	return math.max(cliff, ramp * on_ramp)
end

local function overlook_build(_seed: number): (number, number) -> number
	local half_x = OVERLOOK_SIZE.X / 2
	local half_z = OVERLOOK_SIZE.Y / 2
	return function(x: number, z: number): number
		local hills = overlook_noise(x, z, OVERLOOK_HILL_FREQUENCY, 5.5) * OVERLOOK_HILLS * 2
		local from_edge = math.min(half_x - math.abs(x), half_z - math.abs(z))
		local reach = OVERLOOK_RIM_REACH + overlook_noise(x, z, OVERLOOK_HILL_FREQUENCY, 6.6) * OVERLOOK_RIM_WANDER * 2
		local rim = smoothstep((reach - from_edge) / reach) * OVERLOOK_RIM_TOP
		return OVERLOOK_GROUND + hills + rim + OVERLOOK_DROP * overlook_plateau(x, z)
	end
end

-- The meadow, with no rock on the plateau (it is high, but it is where the player builds), and a dirt track down each
-- ramp so that the way down reads from above.
local OVERLOOK_THEME: Theme = table.clone(MEADOW)
OVERLOOK_THEME.high_ground = nil
OVERLOOK_THEME.high_from = nil
OVERLOOK_THEME.paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
	return function(x: number, z: number, _height: number, too_steep: boolean): Enum.Material?
		local middle = OVERLOOK_RAMP_Z
			+ overlook_noise(x, 0.5, OVERLOOK_RAMP_WIND_FREQUENCY, 4.4) * OVERLOOK_RAMP_WIND * 2
		local down_ramp = x > overlook_edge(z) - 7
			and x < overlook_edge(z) + OVERLOOK_RAMP_RUN + 5
			and math.abs(math.abs(z) - middle) < OVERLOOK_RAMP_HALF - 1
		if down_ramp and too_steep == false then
			return Enum.Material.Ground
		end
		return nil
	end
end

-- Four spots on the plateau for the player, and two in the enemy's base, which it has extractors on from the start.
-- They are ordinary spots, on which an extractor makes 2 metal a second, so the player's four and their commander's 2
-- make the 10 a second the mission's guide asks for (campaign.OVERLOOK.metal).
local OVERLOOK_METAL: { FixedMetalSpot } = {}
for _, at in
	{
		Vector2.new(-58, -24),
		Vector2.new(-58, 24),
		Vector2.new(-40, -35),
		Vector2.new(-40, 35),
		Vector2.new(58, -29),
		Vector2.new(58, 29),
	}
do
	table.insert(OVERLOOK_METAL, { position = at, multiplier = nil })
end

-- Trees on the plateau, and stones fallen from the cliff at its foot and at the feet of the ramps, holding what their
-- defs say.
local function overlook_reclaimables(): { FixedReclaimable }
	local laid: { { def_name: string, at: Vector2 } } = {
		{ def_name = "tree", at = Vector2.new(-70, -49) },
		{ def_name = "tree", at = Vector2.new(-64, -53) },
		{ def_name = "tree", at = Vector2.new(-71, -38) },
		{ def_name = "tree", at = Vector2.new(-68, 48) },
		{ def_name = "tree", at = Vector2.new(-60, 52) },
		{ def_name = "tree", at = Vector2.new(-71, 7) },
		{ def_name = "shrub", at = Vector2.new(-65, -10) },
		{ def_name = "shrub", at = Vector2.new(-32, -16) },
		{ def_name = "shrub", at = Vector2.new(-30, 18) },
		{ def_name = "small_rock", at = Vector2.new(-6, -13) },
		{ def_name = "small_rock", at = Vector2.new(-5, 18) },
		{ def_name = "rock", at = Vector2.new(-7, 2) },
		{ def_name = "small_rock", at = Vector2.new(17, -52) },
		{ def_name = "rock", at = Vector2.new(18, 53) },
	}
	local out: { FixedReclaimable } = {}
	for index, each in laid do
		table.insert(out, {
			def_name = each.def_name,
			position = each.at,
			facing = index * 1.3,
			-- what the defs hold (unit_defs/reclaimable.luau)
			metal = if each.def_name == "small_rock" then 13 elseif each.def_name == "rock" then 21 else 0,
			energy = if each.def_name == "tree" then 250 elseif each.def_name == "shrub" then 50 else 0,
			buildpower = if each.def_name == "small_rock"
				then 78
				elseif each.def_name == "rock" then 126
				elseif each.def_name == "tree" then 1500
				else 300,
		})
	end
	return out
end

local ISLANDS_THEME: Theme = table.clone(TROPICAL)
ISLANDS_THEME.paint = islands_paint

-- The summit to be held is paved, so it reads as the prize from anywhere on the map.
local KOTH_THEME: Theme = table.clone(TEMPERATE)
KOTH_THEME.high_ground = Enum.Material.Pavement
KOTH_THEME.high_from = KOTH_LAYER_3 - 4

-- Beyond All Reason ------------------------------------------------------------------------------------

-- What a rich spot on a BAR map is worth, as metal_spots' own rich spots are.
local BAR_RICH_MULTIPLIER = 4.0

-- Each map is fitted once, the first time anything asks for it, and kept.
local fitted_maps: { [string]: Fitted } = {}

local function fitted(map: BarMap): Fitted
	local existing = fitted_maps[map.name]
	if existing ~= nil then
		return existing
	end
	local made = bar_maps.fit(map)
	fitted_maps[map.name] = made
	return made
end

-- Ground that turns to the map's cliff where it is too steep for bots, whatever the texture says, so the routes read
-- the same as on every other map. Built ground, like a fortress wall or a dam, stays what it is.
local SOFT_GROUND: { [Enum.Material]: boolean } = {
	[Enum.Material.Grass] = true,
	[Enum.Material.LeafyGrass] = true,
	[Enum.Material.Ground] = true,
	[Enum.Material.Mud] = true,
	[Enum.Material.Sand] = true,
}

-- The ground as the map's texture has it, and cliffs beyond its edges.
local function bar_theme(map: BarMap): Theme
	local fallback = map.materials[1]
	return {
		ground = fallback,
		ground_patches = fallback,
		slope = fallback,
		cliff = map.cliff,
		shore = fallback,
		seabed = fallback,
		high_ground = nil,
		high_from = nil,
		colors = map.colors,
		water_color = map.water_color,
		paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
			local fit = fitted(map)
			return function(x: number, z: number, _height: number, too_steep: boolean): Enum.Material?
				local material = fit.material_at(x, z)
				if material == nil or (too_steep and SOFT_GROUND[material] == true) then
					return map.cliff
				end
				return material
			end
		end,
	}
end

-- A BAR map's start boxes, in the world.
local function bar_boxes(map: BarMap, fit: Fitted): { StartBox }
	local boxes: { StartBox } = {}
	for _, box in map.start_boxes do
		local a = fit.to_world(box.min)
		local b = fit.to_world(box.max)
		table.insert(boxes, {
			min = Vector2.new(math.min(a.X, b.X), math.min(a.Y, b.Y)),
			max = Vector2.new(math.max(a.X, b.X), math.max(a.Y, b.Y)),
		})
	end
	return boxes
end

local function bar_preset(map: BarMap): Preset
	local fit = fitted(map)
	local metal: { FixedMetalSpot } = {}
	for _, spot in map.metal do
		table.insert(metal, {
			position = fit.to_world(spot.at),
			multiplier = if spot.rich then BAR_RICH_MULTIPLIER else nil,
		})
	end
	-- what the map has lying on it, from its own archive
	local features = bar_maps.features_of(map.name)
	local vents: { Vector2 } = {}
	for _, at in features.geovents do
		table.insert(vents, fit.to_world(at))
	end
	local function reclaimables(): { FixedReclaimable }
		local out: { FixedReclaimable } = {}
		for _, feature in bar_maps.read_features(features) do
			table.insert(out, {
				def_name = feature.def_name,
				position = fit.to_world(feature.at),
				facing = feature.heading,
				metal = feature.metal,
				energy = feature.energy,
				buildpower = feature.buildpower,
			})
		end
		return out
	end
	return {
		name = map.name,
		description = `By {bar_maps.rights.credit(map.name)}, from Beyond All Reason`,
		size = fit.size,
		build = function(_seed: number): (number, number) -> number
			return fit.height_at
		end,
		start_position = function(slot: number): Vector2
			return fit.to_world(map.starts[(slot - 1) % #map.starts + 1])
		end,
		start_boxes = bar_boxes(map, fit),
		metal_layers = nil,
		metal_spots = metal,
		geo_spots = vents,
		reclaimables = reclaimables,
		theme = bar_theme(map),
		conditions = { min_wind = map.min_wind, max_wind = map.max_wind, tidal_strength = map.tidal_strength },
	}
end

-- Start boxes for the maps made here, laid over their starts by eye. The ring the starts are on puts start 1 east, 2
-- south, 3 west and 4 north, so where there are four boxes the second is the one across from the first, and a game of
-- two starts on opposite sides.
local RING_OPPOSITE_FIRST = { 1, 3, 2, 4 }

local function ring_point(slot: number, radius: number): Vector2
	local angle = (slot - 1) * (math.pi * 2 / config.START_SLOTS)
	return Vector2.new(math.cos(angle), math.sin(angle)) * radius
end

-- A square around each of the four starts on a ring of `radius`, `half` studs out each way.
local function ring_boxes(radius: number, half: number): { StartBox }
	local boxes: { StartBox } = {}
	for _, slot in RING_OPPOSITE_FIRST do
		table.insert(boxes, box_around(ring_point(slot, radius), half))
	end
	return boxes
end

-- The highlands: a strip down each of the east and west sides, each taking in the start there, well clear of the
-- middle.
local HIGHLANDS_BOXES: { StartBox } = {
	{ min = Vector2.new(140, -200), max = Vector2.new(HALF_X - 24, 200) },
	{ min = Vector2.new(-(HALF_X - 24), -200), max = Vector2.new(-140, 200) },
}

-- The continents: the heart of each, far enough in from its coast that the whole box is dry.
local CONTINENTS_BOXES: { StartBox } = {
	{ min = Vector2.new(CONTINENT_CENTER_X - 100, -200), max = Vector2.new(CONTINENT_CENTER_X + 100, 200) },
	{ min = Vector2.new(-CONTINENT_CENTER_X - 100, -200), max = Vector2.new(-CONTINENT_CENTER_X + 100, 200) },
}

-- The islands: the flat top of each start island, which is START_ISLAND_RADIUS across, so a square inside it.
local ISLANDS_BOXES = ring_boxes(config.START_RING_RADIUS, 60)

-- The mountain: each start's stretch of the lowest terrace, between the cliff up to the second and the shore.
local KOTH_BOXES = ring_boxes(KOTH_START_RADIUS, 40)

local presets: { [string]: Preset } = {
	highlands = {
		name = "highlands",
		description = "Rolling hills and sunken basins",
		build = highlands_build,
		size = nil,
		start_position = nil,
		start_boxes = HIGHLANDS_BOXES,
		metal_layers = nil,
		metal_spots = nil,
		theme = TEMPERATE,
		-- A fresh morning in the hills, a little blue in the distance, with a thin mist still lying in the basins.
		atmosphere = {
			clock_time = 10.5,
			latitude = 35,
			brightness = 2.2,
			haze_color = Color3.fromRGB(150, 170, 190),
			decay_color = Color3.fromRGB(100, 120, 140),
			density = 0.3,
			haze = 1.2,
			saturation = 0.05,
			mist = 0.3,
			mist_color = Color3.fromRGB(214, 222, 228),
		},
	},
	islands = {
		name = "islands",
		description = "Islands and a volcano",
		build = islands_build,
		size = nil,
		start_position = nil,
		start_boxes = ISLANDS_BOXES,
		metal_layers = nil,
		metal_spots = nil,
		theme = ISLANDS_THEME,
		-- A tropical afternoon: a high hot sun, a humid sea haze and colours a little brighter than life.
		atmosphere = {
			clock_time = 13.5,
			latitude = 10,
			brightness = 2.6,
			exposure = 0,
			outdoor_ambient = Color3.fromRGB(112, 124, 128),
			haze_color = Color3.fromRGB(160, 196, 204),
			decay_color = Color3.fromRGB(110, 150, 160),
			density = 0.3,
			haze = 1.6,
			glare = 0.3,
			tint = Color3.fromRGB(255, 250, 240),
			saturation = 0.15,
		},
	},
	continents = {
		name = "continents",
		description = "Two continents, two land bridges",
		build = continents_build,
		size = nil,
		start_position = function(slot: number): Vector2
			return CONTINENT_STARTS[(slot - 1) % #CONTINENT_STARTS + 1]
		end,
		start_boxes = CONTINENTS_BOXES,
		metal_layers = nil,
		metal_spots = nil,
		theme = TEMPERATE,
		-- Clear coastal midday, with a blue sea haze on the far shore.
		atmosphere = {
			clock_time = 12.5,
			latitude = 25,
			brightness = 2.4,
			outdoor_ambient = Color3.fromRGB(110, 122, 140),
			haze_color = Color3.fromRGB(130, 160, 190),
			decay_color = Color3.fromRGB(90, 120, 150),
			density = 0.28,
			haze = 1,
		},
	},
	koth = {
		name = "koth",
		description = "A terraced mountain in the sea",
		build = koth_build,
		size = nil,
		start_position = function(slot: number): Vector2
			local angle = (slot - 1) * (math.pi * 2 / config.START_SLOTS)
			return Vector2.new(math.cos(angle), math.sin(angle)) * KOTH_START_RADIUS
		end,
		start_boxes = KOTH_BOXES,
		metal_layers = KOTH_METAL_LAYERS,
		metal_spots = nil,
		geo_at_starts = true,
		theme = KOTH_THEME,
		-- The golden hour on the mountain, with long shadows down its terraces.
		atmosphere = {
			clock_time = 17.2,
			latitude = 30,
			brightness = 2.2,
			sun_color = Color3.fromRGB(60, 36, 10),
			ambient = Color3.fromRGB(96, 90, 100),
			outdoor_ambient = Color3.fromRGB(120, 110, 110),
			haze_color = Color3.fromRGB(200, 160, 120),
			decay_color = Color3.fromRGB(140, 100, 80),
			density = 0.3,
			haze = 1.8,
			glare = 0.5,
		},
	},
	tutorial = {
		name = "tutorial",
		description = "A valley split by a ridge",
		build = tutorial_build,
		size = TUTORIAL_SIZE,
		-- the player's side is the odd slots and the enemy's the even ones
		start_position = function(slot: number): Vector2
			return if slot % 2 == 1 then TUTORIAL_PLAYER_START else TUTORIAL_ENEMY_START
		end,
		start_boxes = { box_around(TUTORIAL_PLAYER_START, 36), box_around(TUTORIAL_ENEMY_START, 36) },
		metal_layers = nil,
		metal_spots = TUTORIAL_METAL,
		reclaimables = tutorial_reclaimables,
		theme = MEADOW,
		campaign_only = true,
		-- A calm, sunny late morning in the valley, with nothing in the way of learning the game.
		atmosphere = {
			clock_time = 11,
			latitude = 25,
			brightness = 2.3,
			haze_color = Color3.fromRGB(150, 175, 200),
			decay_color = Color3.fromRGB(104, 128, 150),
			density = 0.28,
			haze = 1.2,
		},
	},
	overlook = {
		name = "overlook",
		description = "A plateau over the low ground",
		build = overlook_build,
		size = OVERLOOK_SIZE,
		-- the player's side is the odd slots and the enemy's the even ones
		start_position = function(slot: number): Vector2
			return if slot % 2 == 1 then OVERLOOK_PLAYER_START else OVERLOOK_ENEMY_START
		end,
		start_boxes = { box_around(OVERLOOK_PLAYER_START, 22), box_around(OVERLOOK_ENEMY_START, 22) },
		metal_layers = nil,
		metal_spots = OVERLOOK_METAL,
		reclaimables = overlook_reclaimables,
		theme = OVERLOOK_THEME,
		campaign_only = true,
		-- A warm afternoon, the sun lowering over the plateau's edge.
		atmosphere = {
			clock_time = 16.3,
			latitude = 25,
			sun_color = Color3.fromRGB(40, 26, 8),
			haze_color = Color3.fromRGB(190, 170, 140),
			decay_color = Color3.fromRGB(130, 112, 96),
			density = 0.3,
			haze = 1.6,
		},
	},
}

for _, map in bar_maps.MAPS do
	presets[map.name] = bar_preset(map)
end

for _, design in map_designs.ALL do
	presets[design.name] = design
end

local DEFAULT = "highlands"

local function get(name: string?): Preset
	local preset = presets[name or DEFAULT]
	if preset == nil then
		warn(`unknown map preset "{name}"; using {DEFAULT}`)
		return presets[DEFAULT]
	end
	return preset
end

return table.freeze({
	presets = presets,
	DEFAULT = DEFAULT,
	get = get,
})
