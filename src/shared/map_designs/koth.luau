--!strict
-- King of the hill: a mountain in the sea, in three terraces, generated from the seed. The teams start on the lowest
-- and the top is to be held.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)
local themes = require(script.Parent.themes)

type Preset = map_types.Preset
type Theme = map_types.Theme
type MetalLayer = map_types.MetalLayer

local SEA_FLOOR = kit.SEA_FLOOR
-- Four layers, from the sea up: the sea floor, then three terraces, each a plateau standing on the one below.
-- Every layer is a disc around the middle of the map. Their edges are cliffs, steeper than anything walks or is
-- built on, and the only way up from one to the next is a few narrow ramps, at the angles below.
local LAYER_1 = 6
local LAYER_2 = 30
local LAYER_3 = 54
local RADIUS_1 = 350
local SHORE = 34
local RADIUS_2 = 210
local RADIUS_3 = 110
-- How far in from its radius a cliff falls, and so how steep it is: a twenty-four stud drop in five studs.
local CLIFF = 5
-- A ramp climbs a layer's height over this length, which is a quarter as steep as it is high, gently enough for a
-- tank, is this wide from its middle to either side, and is banked by the edge width, which is as steep as a cliff.
local RAMP_LENGTH = 96
local RAMP_HALF_WIDTH = 8
local RAMP_EDGE = 6
local COAST_WARP = 0.04
-- The teams start on the lowest layer, at the four points of the compass.
local START_RADIUS = 265

type Ramp = {
	-- the direction it runs out from the middle, in radians
	angle: number,
	-- the radius of the cliff it climbs
	radius: number,
	lower: number,
	upper: number,
}

-- Between the first and second layers at the diagonals, between the second and third at the other two sides.
local RAMPS: { Ramp } = {}
for index = 0, 3 do
	table.insert(RAMPS, {
		angle = math.rad(45 + index * 90),
		radius = RADIUS_2,
		lower = LAYER_1,
		upper = LAYER_2,
	})
end
for index = 0, 1 do
	table.insert(RAMPS, {
		angle = math.rad(90 + index * 180),
		radius = RADIUS_3,
		lower = LAYER_2,
		upper = LAYER_3,
	})
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local distance = math.sqrt(x * x + z * z)
		local warp = 1 + math.noise(x * kit.COAST_FREQUENCY, z * kit.COAST_FREQUENCY, seed + 6.6) * COAST_WARP
		local shore = kit.smoothstep((RADIUS_1 - distance * warp) / SHORE)
		local height = SEA_FLOOR
			+ (LAYER_1 - SEA_FLOOR) * shore
			+ (LAYER_2 - LAYER_1) * kit.smoothstep((RADIUS_2 - distance) / CLIFF)
			+ (LAYER_3 - LAYER_2) * kit.smoothstep((RADIUS_3 - distance) / CLIFF)

		for _, ramp in RAMPS do
			local along = x * math.cos(ramp.angle) + z * math.sin(ramp.angle)
			-- 0 at the foot, out on the lower layer, and 1 at the top, where the cliff has finished falling away and the
			-- upper layer begins, so the ramp is a bank built up against the cliff and cuts nothing out of the layer above
			local top = ramp.radius - CLIFF
			local climbed = (top + RAMP_LENGTH - along) / RAMP_LENGTH
			if climbed < 0 or climbed > 1 then
				continue
			end
			local across = math.abs(-x * math.sin(ramp.angle) + z * math.cos(ramp.angle))
			local weight = kit.smoothstep((RAMP_HALF_WIDTH + RAMP_EDGE - across) / RAMP_EDGE)
			height += (ramp.lower + (ramp.upper - ramp.lower) * climbed - height) * weight
		end
		return height + kit.ripple(x, z, seed)
	end
end

-- Each layer has its own number of extractors. The top holds few and rich ones, and the sea floor round the
-- island has some too. Bands are a little wider than the ripple on the ground, and narrow enough to leave the
-- ramps out.
local METAL_LAYERS: { MetalLayer } = {
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
		min_height = LAYER_1 - 1.5,
		max_height = LAYER_1 + 1.5,
		count = 10,
		spacing = 60,
		underwater = false,
		multiplier = nil,
		clear_of_starts = true,
	},
	{
		name = "layer 2",
		min_height = LAYER_2 - 1.5,
		max_height = LAYER_2 + 1.5,
		count = 6,
		spacing = 50,
		underwater = false,
		multiplier = nil,
		clear_of_starts = false,
	},
	{
		name = "layer 3",
		min_height = LAYER_3 - 1.5,
		max_height = LAYER_3 + 1.5,
		count = 4,
		spacing = 40,
		underwater = false,
		multiplier = map_types.RICH_MULTIPLIER,
		clear_of_starts = false,
	},
}

-- The summit to be held is paved, so it reads as the prize from anywhere on the map.
local THEME: Theme = table.clone(themes.TEMPERATE)
THEME.high_ground = Enum.Material.Pavement
THEME.high_from = LAYER_3 - 4

return table.freeze({
	name = "koth",
	display_name = "Koth",
	description = "A terraced mountain in the sea",
	source = "generated",
	size = kit.GENERATED_SIZE,
	build = build,
	starts = kit.ring_starts(START_RADIUS),
	-- each start's stretch of the lowest terrace, between the cliff up to the second and the shore
	start_boxes = kit.ring_boxes(START_RADIUS, 40),
	metal_layers = METAL_LAYERS,
	metal_spots = nil,
	geo_at_starts = true,
	theme = THEME,
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
} :: Preset)
