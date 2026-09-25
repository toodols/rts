-- Caldera: a broad volcano in the middle of the map, its crater floor ringed with geothermal vents. The wind barely
-- blows, so the vents are where the energy is: one beside each start, and six down in the crater, with the richest
-- metal on the map between them. The crater's walls are cliffs all round, and its rim shuts off the view into it from
-- outside; the only ways in are two gorges cut through the side of the volcano, north and south, as far from one
-- start as from the other. Whoever holds the rim can see, and shoot, down into the crater.
--
-- The outside of the volcano is gentle enough for anything to drive up, to the rim.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

local at = kit.at

type Preset = map_types.Preset
type Theme = map_types.Theme
type Road = kit.Road

local SIZE = Vector2.new(768, 768)
local GROUND = 5
local ROLL = 1.2
local ROLL_FREQUENCY = 0.02
local NOISE = 43.7
-- The volcano, out from its middle: its foot, the outside of its rim, the inside of it, and the edge of the crater
-- floor, which the inside wall falls to as a cliff.
local FOOT_RADIUS = 250
local RIM_OUTER = 140
local RIM_INNER = 128
local FLOOR_RADIUS = 108
local RIM = 34
local FLOOR = 12
-- Crags along the rim, which make its line ragged without opening it.
local CRAGS = 3
local CRAG_FREQUENCY = 0.09
-- The gorges: level with the crater floor through the rim, and rising gently to the foot outside.
local GORGE_HALF_WIDTH = 9
local GORGE_BANK = 5

local NORTH_GORGE: Road =
	kit.road({ at(0, -FOOT_RADIUS - 15, GROUND), at(0, -190, FLOOR), at(0, -80, FLOOR) }, GORGE_HALF_WIDTH, GORGE_BANK)
local GORGES: { Road } = { NORTH_GORGE, kit.twin_road(NORTH_GORGE) }

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local distance = math.sqrt(x * x + z * z)
		local height: number
		if distance >= RIM_OUTER then
			height = GROUND + (RIM - GROUND) * kit.smoothstep((FOOT_RADIUS - distance) / (FOOT_RADIUS - RIM_OUTER))
		elseif distance >= RIM_INNER then
			height = RIM
		else
			height = FLOOR + (RIM - FLOOR) * kit.smoothstep((distance - FLOOR_RADIUS) / (RIM_INNER - FLOOR_RADIUS))
		end
		-- the crags, strongest on the rim and gone by the foot and the floor
		local on_rim = kit.falloff(math.abs(distance - (RIM_INNER + RIM_OUTER) / 2), 6, 40)
		height += kit.twin_noise(x, z, CRAG_FREQUENCY, NOISE + 1.9 + seed) * CRAGS * on_rim
		height += kit.twin_noise(x, z, ROLL_FREQUENCY, NOISE + seed) * ROLL * (1 - kit.falloff(
			distance,
			FLOOR_RADIUS,
			RIM_INNER
		))
		for _, gorge in GORGES do
			height = kit.lay_road(gorge, x, z, height)
		end
		return height
	end
end

local WEST_START = Vector2.new(-322, 0)

-- Six vents in a ring on the crater floor, and one beside each start.
local VENTS = kit.twinned({
	Vector2.new(68, 0),
	Vector2.new(math.cos(math.rad(120)) * 68, math.sin(math.rad(120)) * 68),
	Vector2.new(math.cos(math.rad(240)) * 68, math.sin(math.rad(240)) * 68),
	Vector2.new(-290, -60),
})

local SPOTS = kit.spots(
	kit.twinned({
		-- home
		Vector2.new(-350, -40),
		Vector2.new(-350, 40),
		Vector2.new(-300, 78),
		Vector2.new(-280, -110),
		Vector2.new(-330, 200),
		Vector2.new(-320, -250),
		-- on the flanks of the volcano
		Vector2.new(-210, 150),
		Vector2.new(-170, -210),
		Vector2.new(-150, 300),
		-- at the mouth of each gorge
		Vector2.new(-40, -280),
	}),
	kit.twinned({ Vector2.new(-26, 22) })
)

local THEME: Theme = {
	ground = Enum.Material.Ground,
	ground_patches = Enum.Material.Mud,
	slope = Enum.Material.Slate,
	cliff = Enum.Material.Basalt,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = Enum.Material.Basalt,
	high_from = RIM - 6,
	colors = {
		[Enum.Material.Ground] = Color3.fromRGB(108, 90, 74),
		[Enum.Material.Mud] = Color3.fromRGB(92, 78, 66),
		[Enum.Material.Slate] = Color3.fromRGB(84, 80, 80),
		[Enum.Material.Basalt] = Color3.fromRGB(56, 52, 52),
		[Enum.Material.CrackedLava] = Color3.fromRGB(196, 92, 44),
	},
	water_color = Color3.fromRGB(46, 70, 84),
	-- the crater floor still smoulders
	paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
		return function(x: number, z: number, _height: number, too_steep: boolean): Enum.Material?
			if too_steep == false and x * x + z * z < FLOOR_RADIUS * FLOOR_RADIUS then
				return Enum.Material.CrackedLava
			end
			return nil
		end
	end,
}

return table.freeze({
	name = "caldera",
	description = "A volcano with geothermal vents in its crater",
	size = SIZE,
	build = build,
	start_position = function(slot: number): Vector2
		return if slot % 2 == 1 then WEST_START else -WEST_START
	end,
	start_boxes = { kit.box_around(WEST_START, 52), kit.box_around(-WEST_START, 52) },
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = VENTS,
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	conditions = { min_wind = 0, max_wind = 4 },
	-- Evening on the volcano: a low red sun through smoke, embers rising off the crater, and smoke lying in the low
	-- ground.
	atmosphere = {
		clock_time = 17.3,
		brightness = 1.9,
		sun_color = Color3.fromRGB(70, 30, 10),
		ambient = Color3.fromRGB(130, 100, 86),
		outdoor_ambient = Color3.fromRGB(160, 122, 104),
		haze_color = Color3.fromRGB(150, 86, 60),
		decay_color = Color3.fromRGB(110, 50, 34),
		density = 0.36,
		haze = 2.2,
		glare = 0.6,
		tint = Color3.fromRGB(255, 236, 222),
		saturation = 0.05,
		weather = "embers",
		weather_amount = 1.1,
		mist = 0.5,
		mist_color = Color3.fromRGB(120, 90, 80),
	},
} :: Preset)
