-- Last stand: made for scavengers. Each side has a fortress, a plateau walled all round by cliffs, with three ramps
-- down to the wide open ground around it; hold the ramps and the fortress holds. The open ground is where the metal is,
-- spread thin, and where the scavengers come from: the start boxes out in its far corners are nobody's in a game of two
-- sides, so the scavengers' first beacon goes up in one of them, and every one after it spreads from there.
--
-- In a game of two sides each has a fortress of its own, the same as the other's.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

type Preset = map_types.Preset
type Theme = map_types.Theme
type Road = kit.Road

local SIZE = Vector2.new(768, 768)
local LOW = 5
local ROLL = 2
local ROLL_FREQUENCY = 0.014
local NOISE = 101.3
-- The fortresses: where the west one is, how far across its top reaches, how high it stands, and how far out its cliff
-- falls, far steeper than anything climbs.
local FORT = Vector2.new(-170, 0)
local FORT_RADIUS = 92
local FORT_TOP = 28
local CLIFF = 7
-- The ramps: the ways they head out from the west fortress, how far each runs from the top of the cliff to the ground,
-- and how wide it is.
local RAMP_ANGLES = { 180, 60, 300 }
local RAMP_RUN = 76
local RAMP_HALF_WIDTH = 7
local RAMP_BANK = 5
-- The metal on the open ground: how many on each side, how far apart, and how far they keep from the fortresses, the
-- ramps and the edge.
local OPEN_SPOTS_EACH = 16
local OPEN_SPACING = 60
local FORT_CLEARANCE = 36
local RAMP_CLEARANCE = 20
local EDGE_MARGIN = 30
local LAYOUT = 424242

local RAMPS: { Road } = {}
for _, angle in RAMP_ANGLES do
	local way = Vector2.new(math.cos(math.rad(angle)), math.sin(math.rad(angle)))
	local top = FORT + way * (FORT_RADIUS - 6)
	local foot = FORT + way * (FORT_RADIUS + RAMP_RUN)
	local road = kit.road({ kit.at(top.X, top.Y, FORT_TOP), kit.at(foot.X, foot.Y, LOW) }, RAMP_HALF_WIDTH, RAMP_BANK)
	table.insert(RAMPS, road)
	table.insert(RAMPS, kit.twin_road(road))
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local ground = LOW + kit.twin_noise(x, z, ROLL_FREQUENCY, NOISE + seed) * ROLL
		local here = Vector2.new(x, z)
		local distance = math.min((here - FORT).Magnitude, (here + FORT).Magnitude)
		local height = kit.lerp(ground, FORT_TOP, kit.smoothstep((FORT_RADIUS + CLIFF - distance) / CLIFF))
		for _, ramp in RAMPS do
			height = kit.lay_road(ramp, x, z, height)
		end
		return height
	end
end

-- The metal out on the open ground, laid out from the layout's own stream, each spot with its twin.
local function open_ground(): { Vector2 }
	local random = kit.stream(LAYOUT)
	local half = SIZE / 2 - Vector2.new(EDGE_MARGIN, EDGE_MARGIN)
	local out: { Vector2 } = {}
	local function clear(at: Vector2): boolean
		if (at - FORT).Magnitude < FORT_RADIUS + CLIFF + FORT_CLEARANCE then
			return false
		end
		if (at + FORT).Magnitude < FORT_RADIUS + CLIFF + FORT_CLEARANCE then
			return false
		end
		for _, ramp in RAMPS do
			if kit.to_road(ramp, at.X, at.Y) < RAMP_HALF_WIDTH + RAMP_BANK + RAMP_CLEARANCE then
				return false
			end
		end
		for _, other in out do
			if (at - other).Magnitude < OPEN_SPACING then
				return false
			end
		end
		return at.Magnitude > OPEN_SPACING / 2
	end
	local placed = 0
	while placed < OPEN_SPOTS_EACH do
		local at = Vector2.new(random.range(-half.X, half.X), random.range(-half.Y, half.Y))
		if clear(at) then
			table.insert(out, at)
			table.insert(out, -at)
			placed += 1
		end
	end
	return out
end

local ordinary = open_ground()
-- in the fortress
for _, offset in
	{ Vector2.new(-40, -30), Vector2.new(-40, 30), Vector2.new(20, -56), Vector2.new(20, 56), Vector2.new(46, 0) }
do
	table.insert(ordinary, FORT + offset)
	table.insert(ordinary, -(FORT + offset))
end

local SPOTS = kit.spots(ordinary, kit.twinned({ Vector2.new(0, -310) }))

-- One vent in each fortress.
local VENTS = kit.twinned({ FORT + Vector2.new(-10, 58) })

local THEME: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.Ground,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Slate,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	-- the fortresses are paved
	high_ground = Enum.Material.Pavement,
	high_from = FORT_TOP - 3,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(106, 128, 70),
		[Enum.Material.Ground] = Color3.fromRGB(122, 104, 78),
		[Enum.Material.Slate] = Color3.fromRGB(96, 96, 100),
		[Enum.Material.Pavement] = Color3.fromRGB(148, 146, 140),
	},
	water_color = Color3.fromRGB(44, 80, 104),
	paint = nil,
}

-- The two fortresses first, so that two sides get one each, and then the open corners, the one furthest from the first
-- fortress first.
local BOXES = {
	kit.box_around(FORT, 50),
	kit.box_around(-FORT, 50),
	kit.box_around(Vector2.new(300, 300), 56),
	kit.box_around(Vector2.new(-300, -300), 56),
}

return table.freeze({
	name = "last_stand",
	description = "Two fortresses on open ground",
	size = SIZE,
	build = build,
	start_position = function(slot: number): Vector2
		return if slot % 2 == 1 then FORT else -FORT
	end,
	start_boxes = BOXES,
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = VENTS,
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	conditions = nil,
	-- Dusk and a storm coming in: a bruised purple sky, the last of the sun, and rain on the wind.
	atmosphere = {
		clock_time = 17.5,
		latitude = 30,
		brightness = 1.7,
		sun_color = Color3.fromRGB(60, 24, 24),
		ambient = Color3.fromRGB(106, 96, 120),
		outdoor_ambient = Color3.fromRGB(132, 118, 148),
		haze_color = Color3.fromRGB(130, 100, 120),
		decay_color = Color3.fromRGB(90, 60, 80),
		density = 0.34,
		haze = 1.8,
		glare = 0.4,
		saturation = -0.05,
		weather = "rain",
		weather_amount = 0.6,
		mist = 0.3,
		mist_color = Color3.fromRGB(150, 136, 160),
	},
} :: Preset)
