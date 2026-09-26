--!strict
-- Switchbacks: a plateau in the middle of the map whose long faces a bot walks straight up and a tank cannot, between
-- the two sides' low ground. A tank or a hovercraft climbs by the switchback roads cut into the faces, two on each side,
-- so the same climb is a short walk for a bot and a long drive for the rest. The only other way from one side to the
-- other is by water, along the river at each end, which a hovercraft or a boat takes.
--
-- The plateau is a stadium, a line from north to south with PLATEAU_RADIUS all round it, and its faces fall over FACE
-- studs in an S, at most about 42 degrees: under the 54 a bot climbs, over the 27 a tank does and the 33 a hovercraft
-- does. Each road climbs the face in three legs along it, each turning back on the last, at about 8 degrees, and is
-- walled from the face above and below by banks steeper than anything climbs.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

local at = kit.at

type Preset = map_types.Preset
type Theme = map_types.Theme
type Road = kit.Road

local SIZE = Vector2.new(768, 768)
local LOW = 5
local TOP = 36
-- The plateau: the line down its middle runs this far either side of z = 0, and its top reaches this far from the line.
local PLATEAU_HALF_LENGTH = 175
local PLATEAU_RADIUS = 150
local FACE = 52
-- Gullies worn into the faces and a roll to the ground everywhere, both slight enough to leave every slope what it is.
local RILLS = 1.5
local RILL_FREQUENCY = 0.08
local ROLL = 1.2
local ROLL_FREQUENCY = 0.02
-- The rivers along the north and south edges, where a hovercraft goes round: their middle, how far across either side
-- of it the bed is at its deepest, how far more it takes to rise to the bank, and how deep they are. They run along the
-- edge of the map, and the plateau's ends fall straight into them, so there is no way round on dry ground.
local RIVER_Z = 368
local RIVER_HALF_WIDTH = 18
local RIVER_BANK = 12
local RIVER_BED = -3.5
local NOISE = 17.3

-- The west side's north road, a leg at a time: in from the low ground, up along the face, back, up again, and out onto
-- the plateau. The others are it mirrored north to south, and both of those turned half way round the middle.
local LEG_1_X = -PLATEAU_RADIUS - 46
local LEG_2_X = -PLATEAU_RADIUS - 26
local LEG_3_X = -PLATEAU_RADIUS - 6
local LEG_NEAR_Z = 30
local LEG_FAR_Z = 100
local ROAD_HALF_WIDTH = 5
local ROAD_BANK = 5
local THIRD = (TOP - LOW) / 3

local NORTH_WEST: Road = kit.road({
	at(LEG_1_X - 30, LEG_NEAR_Z, LOW),
	at(LEG_1_X, LEG_NEAR_Z, LOW),
	at(LEG_1_X, LEG_FAR_Z, LOW + THIRD),
	at(LEG_2_X, LEG_FAR_Z, LOW + THIRD),
	at(LEG_2_X, LEG_NEAR_Z, LOW + THIRD * 2),
	at(LEG_3_X, LEG_NEAR_Z, LOW + THIRD * 2),
	at(LEG_3_X, LEG_FAR_Z, TOP),
	at(LEG_3_X + 30, LEG_FAR_Z, TOP),
}, ROAD_HALF_WIDTH, ROAD_BANK)

local function mirrored_north_south(road: Road): Road
	local points: { Vector3 } = {}
	for _, point in road.points do
		table.insert(points, Vector3.new(point.X, point.Y, -point.Z))
	end
	return kit.road(points, road.half_width, road.bank)
end

local SOUTH_WEST = mirrored_north_south(NORTH_WEST)
local ROADS: { Road } = { NORTH_WEST, SOUTH_WEST, kit.twin_road(NORTH_WEST), kit.twin_road(SOUTH_WEST) }

-- How far (x, z) is from the line down the middle of the plateau.
local function from_spine(x: number, z: number): number
	local along = math.clamp(z, -PLATEAU_HALF_LENGTH, PLATEAU_HALF_LENGTH)
	return math.sqrt(x * x + (z - along) ^ 2)
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local roll = kit.twin_noise(x, z, ROLL_FREQUENCY, NOISE + seed) * ROLL
		local rise = kit.smoothstep((PLATEAU_RADIUS + FACE - from_spine(x, z)) / FACE)
		-- the gullies only on the face, where the rise is under way
		local rills = kit.twin_noise(x, z, RILL_FREQUENCY, NOISE + 1.1 + seed) * RILLS * rise * (1 - rise) * 4
		local height = LOW + roll + (TOP - LOW) * rise + rills

		for _, road in ROADS do
			height = kit.lay_road(road, x, z, height)
		end

		local river = math.abs(math.abs(z) - RIVER_Z)
		local sunk = kit.smoothstep((RIVER_HALF_WIDTH + RIVER_BANK - river) / RIVER_BANK)
		return kit.lerp(height, RIVER_BED, sunk)
	end
end

local THEME: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.LeafyGrass,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Rock,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Mud,
	high_ground = nil,
	high_from = nil,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(104, 132, 66),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(88, 118, 58),
		[Enum.Material.Ground] = Color3.fromRGB(124, 100, 72),
		[Enum.Material.Rock] = Color3.fromRGB(106, 102, 96),
		[Enum.Material.Cobblestone] = Color3.fromRGB(138, 130, 116),
	},
	water_color = Color3.fromRGB(44, 88, 104),
	-- the roads are cobbled, so the way up for a tank reads from anywhere
	paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
		return function(x: number, z: number, _height: number, too_steep: boolean): Enum.Material?
			if too_steep then
				return nil
			end
			for _, road in ROADS do
				local distance = kit.to_road(road, x, z)
				if distance < ROAD_HALF_WIDTH then
					return Enum.Material.Cobblestone
				end
			end
			return nil
		end
	end,
}

local WEST_START = Vector2.new(-300, 0)

local SPOTS = kit.spots(
	kit.twinned({
		-- home
		Vector2.new(-332, -44),
		Vector2.new(-332, 44),
		Vector2.new(-286, -78),
		Vector2.new(-286, 78),
		Vector2.new(-252, -150),
		Vector2.new(-252, 150),
		-- by the rivers
		Vector2.new(-300, -300),
		Vector2.new(-300, 300),
		-- on the plateau
		Vector2.new(-96, -64),
		Vector2.new(-96, 64),
		Vector2.new(-60, -230),
		Vector2.new(0, -230),
		-- in the rivers
		Vector2.new(-120, -RIVER_Z),
	}),
	kit.twinned({ Vector2.new(-36, 0) })
)

return table.freeze({
	name = "switchbacks",
	display_name = "Switchbacks",
	description = "A plateau with switchback roads",
	source = "design",
	size = SIZE,
	build = build,
	-- one side's players start on the west, the other's on the east
	starts = { WEST_START, -WEST_START },
	start_boxes = { kit.box_around(WEST_START, 60), kit.box_around(-WEST_START, 60) },
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = nil,
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	conditions = nil,
	-- A wet day in green hill country: low grey cloud, cool wet light, rain in squalls and a mist along the rivers.
	atmosphere = {
		clock_time = 13,
		brightness = 1.4,
		exposure = -0.2,
		ambient = Color3.fromRGB(96, 102, 110),
		outdoor_ambient = Color3.fromRGB(116, 124, 134),
		haze_color = Color3.fromRGB(150, 160, 168),
		decay_color = Color3.fromRGB(110, 118, 126),
		density = 0.38,
		haze = 2,
		glare = 0,
		saturation = -0.2,
		weather = "rain",
		weather_amount = 1.1,
		tint = Color3.fromRGB(216, 226, 238),
		contrast = 0.06,
		mist = 0.4,
		mist_color = Color3.fromRGB(186, 194, 202),
	},
} :: Preset)
