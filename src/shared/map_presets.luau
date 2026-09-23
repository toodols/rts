-- Map generation presets. A preset turns the seed into a height function over the whole map, in world
-- coordinates, and the heightmap samples it at every grid point. Each is a pure function of the seed, so
-- the server and the client build the same ground without it being sent.
--
-- highlands: rolling hills with basins that dip below the sea in places, the map as it always was.
-- continents: two continents side by side, joined by two narrow land bridges, with sea all around.
-- islands: islands in an ocean, one under every start, more scattered between, and at least one volcano,
--   a cone far steeper than anything can be built on.
-- koth: a mountain in the sea, in three terraces. The teams start on the lowest and the top is to be held.
-- supreme_isthmus, hooked, center_command, rifted, comet_catcher, altair_crossing, ancient_bastion, folsom_dam:
--   Beyond All Reason's maps of those names, from their heightmaps, textures and metal maps (see bar_maps).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local config = require(ReplicatedStorage.Shared.config)
local bar_maps = require(ReplicatedStorage.Shared.bar_maps)
local environment = require(ReplicatedStorage.Shared.environment)

type BarMap = bar_maps.BarMap
type Fitted = bar_maps.Fitted

-- One band of ground that has metal spots of its own, so that each layer of a map is worth a set number of them.
export type MetalLayer = {
	name: string,
	-- the spots stand on ground between these heights
	min_height: number,
	max_height: number,
	count: number,
	-- how far apart its spots keep, in studs
	spacing: number,
	-- on the sea floor rather than dry land
	underwater: boolean,
	-- what an extractor's income is multiplied by there; nil for the ordinary amount
	multiplier: number?,
	-- kept clear of the start positions, as the spots on the open ground are
	clear_of_starts: boolean,
}

-- What the ground of a map is made of. Terrain paints every column from this (see server/terrain.luau): the
-- map's own features decide first, then the steepness, so the routes read off the ground, then the height, then
-- patches of noise.
export type Theme = {
	-- open ground, which everything can drive over, and the second material it is mottled with
	ground: Enum.Material,
	ground_patches: Enum.Material,
	-- too steep for tanks, not for bots
	slope: Enum.Material,
	-- too steep for anything that walks
	cliff: Enum.Material,
	-- ground within a stud or two of the waterline, and the sea floor below that
	shore: Enum.Material,
	seabed: Enum.Material,
	-- open ground from about this height up is `high_ground` instead, like snow on the peaks; nil for none
	high_ground: Enum.Material?,
	high_from: number?,
	-- the colours the map gives its materials; any it leaves out keep Roblox's own
	colors: { [Enum.Material]: Color3 },
	water_color: Color3,
	-- the map's own features, given the seed: a material for a place, told whether the ground there is too steep for
	-- bots, or nil to leave it to the rules above
	paint: ((seed: number) -> (x: number, z: number, height: number, too_steep: boolean) -> Enum.Material?)?,
}

-- A metal spot a map puts in a place of its own choosing, in world (x, z).
export type FixedMetalSpot = {
	position: Vector2,
	-- nil for the ordinary amount
	multiplier: number?,
}

export type Preset = {
	name: string,
	description: string,
	-- How big the map is, in studs along x and z, rounded to an even number of cells; nil for config's MAP_CELLS_X by
	-- MAP_CELLS_Z.
	size: Vector2?,
	-- Gives the ground height at a world position.
	build: (seed: number) -> (x: number, z: number) -> number,
	-- Where a team's start ideally is, as (x, z); nil puts them on a ring around the middle.
	start_position: ((slot: number) -> Vector2)?,
	-- How many different starts the map has, which players choose among; nil for config's START_SLOTS.
	start_count: number?,
	-- The layers the middle spots are laid out in, each with its own count, in place of the usual scatter
	-- over the whole map and the spots on the sea floor.
	metal_layers: { MetalLayer }?,
	-- Every metal spot on the map, where the map says, in place of any laid out from the seed; nil to lay them out.
	metal_spots: { FixedMetalSpot }?,
	theme: Theme,
	-- The least and most the wind blows, and how strong the tide is (see environment.luau); any left nil is config's
	-- default.
	conditions: environment.Conditions?,
}

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

local function bar_preset(map: BarMap): Preset
	local fit = fitted(map)
	local metal: { FixedMetalSpot } = {}
	for _, spot in map.metal do
		table.insert(metal, {
			position = fit.to_world(spot.at),
			multiplier = if spot.rich then BAR_RICH_MULTIPLIER else nil,
		})
	end
	return {
		name = map.name,
		description = `{map.display_name}, from Beyond All Reason, as big as it is there`,
		size = fit.size,
		build = function(_seed: number): (number, number) -> number
			return fit.height_at
		end,
		start_position = function(slot: number): Vector2
			return fit.to_world(map.starts[(slot - 1) % #map.starts + 1])
		end,
		start_count = #map.starts,
		metal_layers = nil,
		metal_spots = metal,
		theme = bar_theme(map),
		conditions = { min_wind = map.min_wind, max_wind = map.max_wind, tidal_strength = map.tidal_strength },
	}
end

local presets: { [string]: Preset } = {
	highlands = {
		name = "highlands",
		description = "Rolling hills, with basins that dip below the sea in places",
		build = highlands_build,
		size = nil,
		start_position = nil,
		metal_layers = nil,
		metal_spots = nil,
		theme = TEMPERATE,
	},
	islands = {
		name = "islands",
		description = "Islands in an ocean, one under every start and at least one steep volcano",
		build = islands_build,
		size = nil,
		start_position = nil,
		metal_layers = nil,
		metal_spots = nil,
		theme = ISLANDS_THEME,
	},
	continents = {
		name = "continents",
		description = "Two continents joined by two narrow land bridges, one team on each side, in a surrounding sea",
		build = continents_build,
		size = nil,
		start_position = function(slot: number): Vector2
			return CONTINENT_STARTS[(slot - 1) % #CONTINENT_STARTS + 1]
		end,
		metal_layers = nil,
		metal_spots = nil,
		theme = TEMPERATE,
	},
	koth = {
		name = "koth",
		description = "A mountain in the sea, in three terraces joined by narrow ramps, with metal on every layer",
		build = koth_build,
		size = nil,
		start_position = function(slot: number): Vector2
			local angle = (slot - 1) * (math.pi * 2 / config.START_SLOTS)
			return Vector2.new(math.cos(angle), math.sin(angle)) * KOTH_START_RADIUS
		end,
		metal_layers = KOTH_METAL_LAYERS,
		metal_spots = nil,
		theme = KOTH_THEME,
	},
}

for _, map in bar_maps.MAPS do
	presets[map.name] = bar_preset(map)
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
