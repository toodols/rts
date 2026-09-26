--!strict
-- Gale: a small, bare tundra for one against one, where the wind never drops. There is no water for a tidal generator,
-- no tree to reclaim, and not much metal, so the energy is the wind's, and a game is quick. Long, low ridges carved by
-- the wind run across it from west to east, the way it blows, gentle enough for anything to drive over.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

type Preset = map_types.Preset
type Theme = map_types.Theme

local SIZE = Vector2.new(512, 512)
local GROUND = 6
local ROLL = 1.5
local ROLL_FREQUENCY = 0.02
local NOISE = 97.7
-- The ridges: each is a long mound along x, `length` from end to end and `width` across, `height` high at its middle.
local RIDGE_HEIGHT = 4
type Ridge = { center: Vector2, length: number, width: number }

local RIDGES: { Ridge } = {}
for _, ridge in
	{
		{ center = Vector2.new(-150, -170), length = 150, width = 34 },
		{ center = Vector2.new(-60, -90), length = 120, width = 30 },
		{ center = Vector2.new(-190, 110), length = 110, width = 30 },
		{ center = Vector2.new(-40, 170), length = 160, width = 36 },
		{ center = Vector2.new(-100, 30), length = 70, width = 26 },
	} :: { Ridge }
do
	table.insert(RIDGES, ridge)
	table.insert(RIDGES, { center = -ridge.center, length = ridge.length, width = ridge.width })
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local height = GROUND + kit.twin_noise(x, z, ROLL_FREQUENCY, NOISE + seed) * ROLL
		for _, ridge in RIDGES do
			local along = (x - ridge.center.X) / (ridge.length / 2)
			local across = (z - ridge.center.Y) / (ridge.width / 2)
			local distance = math.sqrt(along * along + across * across)
			if distance < 1 then
				-- a mound that rises steadily from its edge and rounds off at its crest
				height += RIDGE_HEIGHT * kit.smoothstep(1 - distance)
			end
		end
		return height
	end
end

local WEST_START = Vector2.new(-186, 0)

local SPOTS = kit.spots(
	kit.twinned({
		-- home
		Vector2.new(-214, -36),
		Vector2.new(-214, 36),
		Vector2.new(-166, -60),
		Vector2.new(-166, 60),
		-- further out
		Vector2.new(-200, -120),
		Vector2.new(-120, 150),
		-- the middle
		Vector2.new(-40, -30),
		Vector2.new(-20, -200),
	}),
	nil
)

local THEME: Theme = {
	ground = Enum.Material.Snow,
	ground_patches = Enum.Material.Glacier,
	slope = Enum.Material.Rock,
	cliff = Enum.Material.Rock,
	shore = Enum.Material.Snow,
	seabed = Enum.Material.Ground,
	high_ground = Enum.Material.Rock,
	high_from = GROUND + RIDGE_HEIGHT + 0.5,
	colors = {
		[Enum.Material.Snow] = Color3.fromRGB(222, 228, 234),
		[Enum.Material.Glacier] = Color3.fromRGB(186, 206, 220),
		[Enum.Material.Rock] = Color3.fromRGB(118, 120, 124),
		[Enum.Material.Ground] = Color3.fromRGB(110, 100, 88),
	},
	water_color = Color3.fromRGB(60, 90, 110),
	paint = nil,
}

return table.freeze({
	name = "gale",
	display_name = "Gale",
	description = "A small windswept tundra",
	source = "design",
	size = SIZE,
	build = build,
	starts = { WEST_START, -WEST_START },
	start_boxes = { kit.box_around(WEST_START, 44), kit.box_around(-WEST_START, 44) },
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = nil,
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	conditions = { min_wind = 12, max_wind = 25 },
	-- A blizzard on the tundra: cold blue light, white haze, and snow driven along by the wind.
	atmosphere = {
		clock_time = 13,
		latitude = 65,
		brightness = 1.8,
		ambient = Color3.fromRGB(110, 120, 136),
		outdoor_ambient = Color3.fromRGB(140, 152, 172),
		haze_color = Color3.fromRGB(200, 212, 226),
		decay_color = Color3.fromRGB(160, 176, 196),
		density = 0.4,
		haze = 2.4,
		glare = 0.2,
		tint = Color3.fromRGB(236, 244, 255),
		saturation = -0.1,
		weather = "snow",
		weather_amount = 1.3,
	},
} :: Preset)
