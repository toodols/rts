-- Tidal flats: two coasts, west and east, with a broad flat of shallow water between them. It is too deep for anything
-- that cannot go in water, which is most of what walks and drives, and too shallow for all but the lightest boats; a
-- hovercraft skims it, and an amphibious unit wades it. Sandbars stand out of it with metal on them, for whatever can
-- reach them. The only way across for the rest is one causeway through the middle, over an island.
--
-- To the north and the south the flat gives way to deep sea, the only water deep enough for the big ships and for a
-- tidal generator, and the tide is strong and the wind weak, so the energy is out there too.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

type Preset = map_types.Preset
type Theme = map_types.Theme

local SIZE = Vector2.new(768, 768)
local LAND = 5
-- The coasts: dry ground from this far out from x = 0, falling to the water over COAST studs, and wandering a little.
local COAST_X = 214
local COAST = 30
local COAST_WANDER = 18
local COAST_WANDER_FREQUENCY = 0.012
-- The flat: this deep, give or take its ripple, which never brings it near enough the surface for anything to stand in
-- it that cannot go in water (see config.DROWN_DEPTH_MARGIN), and never deep enough for a tidal generator.
local FLAT = -1.35
local FLAT_RIPPLE = 0.25
local FLAT_RIPPLE_FREQUENCY = 0.05
-- The deep sea to the north and south: from this far out from z = 0 the flat has fallen to it, over SHELF studs.
local DEEP = -6
local DEEP_Z = 250
local SHELF = 50
-- The sandbars and the island in the middle: how high their tops stand, and how far their shores run out.
local BAR_TOP = 2.2
local BAR_SHORE = 10
local ISLAND_RADIUS = 36
-- The causeway: how far either side of z = 0 its top is, how far its banks run, and how high it stands.
local CAUSEWAY_HALF_WIDTH = 7
local CAUSEWAY_BANK = 6
local CAUSEWAY_TOP = 2.2
local ROLL = 1.2
local ROLL_FREQUENCY = 0.02
local NOISE = 23.9

type Bar = { center: Vector2, radius: number }

-- One side's sandbars, each with its twin across the middle.
local BARS: { Bar } = {}
for _, bar in
	{
		{ center = Vector2.new(-130, -70), radius = 26 },
		{ center = Vector2.new(-124, 112), radius = 30 },
		{ center = Vector2.new(-60, -150), radius = 28 },
		{ center = Vector2.new(-44, 76), radius = 22 },
		{ center = Vector2.new(-150, 186), radius = 24 },
	} :: { Bar }
do
	table.insert(BARS, bar)
	table.insert(BARS, { center = -bar.center, radius = bar.radius })
end
table.insert(BARS, { center = Vector2.zero, radius = ISLAND_RADIUS })

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local sea = kit.lerp(FLAT, DEEP, kit.smoothstep((math.abs(z) - DEEP_Z + SHELF) / SHELF))
			+ kit.twin_noise(x, z, FLAT_RIPPLE_FREQUENCY, NOISE + seed) * FLAT_RIPPLE
		-- the east coast wanders as the west one does, turned half way round the middle
		local wander = kit.noise(0.5, if x < 0 then z else -z, COAST_WANDER_FREQUENCY, NOISE + 1.3 + seed)
			* COAST_WANDER
		local coast = kit.smoothstep((math.abs(x) - COAST_X + wander + COAST) / COAST)
		local land = LAND + kit.twin_noise(x, z, ROLL_FREQUENCY, NOISE + 2.2 + seed) * ROLL
		local height = kit.lerp(sea, land, coast)

		for _, bar in BARS do
			local distance = (Vector2.new(x, z) - bar.center).Magnitude
			local rise = kit.falloff(distance, bar.radius - BAR_SHORE, bar.radius)
			height = math.max(height, kit.lerp(sea, BAR_TOP, rise))
		end

		if math.abs(x) < COAST_X then
			local rise = kit.smoothstep((CAUSEWAY_HALF_WIDTH + CAUSEWAY_BANK - math.abs(z)) / CAUSEWAY_BANK)
			height = math.max(height, kit.lerp(sea, CAUSEWAY_TOP, rise))
		end
		return height
	end
end

local THEME: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.Ground,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Rock,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = nil,
	high_from = nil,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(112, 134, 72),
		[Enum.Material.Ground] = Color3.fromRGB(126, 108, 78),
		[Enum.Material.Sand] = Color3.fromRGB(206, 190, 146),
		[Enum.Material.Mud] = Color3.fromRGB(108, 94, 72),
		[Enum.Material.Rock] = Color3.fromRGB(110, 104, 96),
	},
	water_color = Color3.fromRGB(52, 112, 118),
	-- the flat is mud, and the deep sea beyond it sand
	paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
		return function(_x: number, _z: number, height: number, _too_steep: boolean): Enum.Material?
			if height < -0.6 and height > FLAT - 0.8 then
				return Enum.Material.Mud
			end
			return nil
		end
	end,
}

local WEST_START = Vector2.new(-300, 0)

local ordinary: { Vector2 } = {
	-- home
	Vector2.new(-330, -46),
	Vector2.new(-330, 46),
	Vector2.new(-282, -84),
	Vector2.new(-282, 84),
	Vector2.new(-320, -170),
	Vector2.new(-320, 170),
	Vector2.new(-262, -250),
	Vector2.new(-262, 250),
	-- in the deep sea, north and south
	Vector2.new(-150, -330),
	Vector2.new(-40, 320),
}
-- one on every sandbar
for index = 1, #BARS - 1, 2 do
	table.insert(ordinary, BARS[index].center)
end

local SPOTS = kit.spots(kit.twinned(ordinary), kit.twinned({ Vector2.new(-14, -12) }))

return table.freeze({
	name = "tidal_flats",
	description = "Mudflats, sandbars and one causeway",
	size = SIZE,
	build = build,
	start_position = function(slot: number): Vector2
		return if slot % 2 == 1 then WEST_START else -WEST_START
	end,
	start_boxes = { kit.box_around(WEST_START, 60), kit.box_around(-WEST_START, 60) },
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = nil,
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	conditions = { min_wind = 0, max_wind = 6, tidal_strength = 22 },
	-- Dawn over the mudflats: a low sun through a pale sea mist.
	atmosphere = {
		clock_time = 7.2,
		latitude = 40,
		brightness = 1.6,
		sun_color = Color3.fromRGB(30, 20, 10),
		ambient = Color3.fromRGB(100, 106, 116),
		outdoor_ambient = Color3.fromRGB(130, 136, 146),
		haze_color = Color3.fromRGB(196, 200, 204),
		decay_color = Color3.fromRGB(160, 164, 170),
		density = 0.42,
		haze = 2.6,
		glare = 0.3,
		saturation = -0.1,
		mist = 1,
		mist_color = Color3.fromRGB(226, 228, 230),
	},
} :: Preset)
