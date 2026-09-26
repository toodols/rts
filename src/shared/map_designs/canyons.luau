--!strict
-- Canyons: a tableland between the two sides' low ground, cut through by a maze of narrow canyons with sheer walls.
-- Down in them nothing sees past the next bend, so a fight is close and sudden, and an ambush at a junction beats a
-- longer range. The canyons open out where they meet, and the metal is in those plazas.
--
-- Anything can drive the canyons. Only a bot can get up onto the tableland: by the slope that climbs to it from each
-- side's low ground, and by the narrow ramps that climb out of the plazas onto the pieces the canyons cut off. From up
-- there it looks down into the canyons.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

type Preset = map_types.Preset
type Theme = map_types.Theme
type Road = kit.Road

local SIZE = Vector2.new(768, 768)
local LOW = 6
local TOP = 30
-- The tableland reaches this far out from x = 0 before its slope down to the low ground, which is steep enough to keep
-- tanks off it, and not bots.
local TABLE_X = 238
local TABLE_SLOPE = 40
-- A canyon's floor is this far either side of its line, and its walls rise to the top over WALL more, as a cliff; where
-- canyons meet, a plaza this far round.
local CANYON_HALF_WIDTH = 10
local WALL = 5
local PLAZA_RADIUS = 20
local ROLL = 0.8
local ROLL_FREQUENCY = 0.03
local CRAGS = 1.5
local CRAG_FREQUENCY = 0.08
local NOISE = 83.1

-- The junctions on the west side, and the canyons between them; the east side has the twin of each. Some canyons run
-- from a junction on the west to the twin of another, across the middle.
local JUNCTIONS: { [string]: Vector2 } = {
	a = Vector2.new(-262, -210),
	b = Vector2.new(-262, 0),
	c = Vector2.new(-262, 210),
	d = Vector2.new(-160, -280),
	e = Vector2.new(-160, -96),
	f = Vector2.new(-160, 110),
	g = Vector2.new(-160, 290),
	h = Vector2.new(-64, -190),
	i = Vector2.new(-60, 26),
	j = Vector2.new(-64, 214),
}
-- The pairs, each a junction's name, or with a ' the name of the one whose twin it is.
local LINKS: { { string } } = {
	{ "a", "d" },
	{ "a", "e" },
	{ "b", "e" },
	{ "b", "f" },
	{ "c", "f" },
	{ "c", "g" },
	{ "d", "h" },
	{ "e", "h" },
	{ "e", "i" },
	{ "f", "i" },
	{ "f", "j" },
	{ "g", "j" },
	{ "h", "j'" },
	{ "i", "i'" },
}

local function junction(name: string): Vector2
	if string.sub(name, -1) == "'" then
		return -JUNCTIONS[string.sub(name, 1, -2)]
	end
	return JUNCTIONS[name]
end

-- A canyon's line, and the box it cuts the ground within.
type Segment = { from: Vector2, to: Vector2, low: Vector2, high: Vector2 }

local function segment(from: Vector2, to: Vector2): Segment
	local reach = Vector2.new(CANYON_HALF_WIDTH + WALL, CANYON_HALF_WIDTH + WALL)
	return { from = from, to = to, low = from:Min(to) - reach, high = from:Max(to) + reach }
end

local SEGMENTS: { Segment } = {}
for _, link in LINKS do
	local from, to = junction(link[1]), junction(link[2])
	table.insert(SEGMENTS, segment(from, to))
	-- its twin, unless it is its own
	if link[2] ~= link[1] .. "'" then
		table.insert(SEGMENTS, segment(-from, -to))
	end
end
-- the plazas at every junction and its twin, but the ones out on the low ground, which is open already
local PLAZAS: { Vector2 } = {}
for name, at in JUNCTIONS do
	if name ~= "a" and name ~= "b" and name ~= "c" then
		table.insert(PLAZAS, at)
		table.insert(PLAZAS, -at)
	end
end

-- Where the canyons shut a piece of the tableland off from the rest, a bot climbs to it by a ramp out of a plaza: level
-- across the plaza, then up at about 39 degrees, steeper than a tank or a hovercraft climbs. Each is the plaza it starts
-- in and the way it heads, on the west side; the east side has their twins.
local RAMP_RISE = 30
local RAMP_HALF_WIDTH = 3.5
local RAMP_BANK = 3
local RAMPS: { Road } = {}
for _, ramp in
	{
		{ from = "e", toward = Vector2.new(0, -1) },
		{ from = "f", toward = Vector2.new(0, -1) },
		{ from = "j", toward = Vector2.new(-1, -0.1) },
		{ from = "h", toward = Vector2.new(0.55, 0.83) },
	}
do
	local start = JUNCTIONS[ramp.from]
	local way = ramp.toward.Unit
	local foot = start + way * (PLAZA_RADIUS - 2)
	local top = foot + way * RAMP_RISE
	local road = kit.road(
		{ kit.at(start.X, start.Y, LOW), kit.at(foot.X, foot.Y, LOW), kit.at(top.X, top.Y, TOP) },
		RAMP_HALF_WIDTH,
		RAMP_BANK
	)
	table.insert(RAMPS, road)
	table.insert(RAMPS, kit.twin_road(road))
end

-- How far down into the canyons (x, z) is: 1 on a canyon's floor, 0 on the tableland.
local function cut(x: number, z: number): number
	local deepest = 0
	for _, canyon in SEGMENTS do
		if kit.within(x, z, canyon.low, canyon.high) then
			local distance = kit.to_segment(x, z, canyon.from, canyon.to)
			deepest = math.max(deepest, kit.smoothstep((CANYON_HALF_WIDTH + WALL - distance) / WALL))
		end
	end
	for _, plaza in PLAZAS do
		local distance = (Vector2.new(x, z) - plaza).Magnitude
		deepest = math.max(deepest, kit.smoothstep((PLAZA_RADIUS + WALL - distance) / WALL))
	end
	return deepest
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local roll = kit.twin_noise(x, z, ROLL_FREQUENCY, NOISE + seed) * ROLL
		local crags = kit.twin_noise(x, z, CRAG_FREQUENCY, NOISE + 1.7 + seed) * CRAGS
		local tableland = kit.smoothstep((TABLE_X + TABLE_SLOPE - math.abs(x)) / TABLE_SLOPE)
		local height = kit.lerp(kit.lerp(LOW + roll, TOP + crags, tableland), LOW + roll, cut(x, z))
		for _, ramp in RAMPS do
			height = kit.lay_road(ramp, x, z, height)
		end
		return height
	end
end

local WEST_START = Vector2.new(-326, 0)

local ordinary: { Vector2 } = {
	-- home
	Vector2.new(-352, -44),
	Vector2.new(-352, 44),
	Vector2.new(-312, -100),
	Vector2.new(-312, 100),
	Vector2.new(-340, -250),
	Vector2.new(-340, 250),
	Vector2.new(-300, -330),
	Vector2.new(-300, 330),
	-- on the pieces of the tableland the ramps climb to, for the bots
	Vector2.new(-164, -198),
	Vector2.new(-163, 0),
	Vector2.new(-164, 206),
	Vector2.new(-6, -110),
}
-- one in every plaza on the west side, a little off its middle
for name, at in JUNCTIONS do
	if name ~= "a" and name ~= "b" and name ~= "c" then
		table.insert(ordinary, at + Vector2.new(-8, 6))
	end
end
table.sort(ordinary, function(a: Vector2, b: Vector2): boolean
	return if a.X ~= b.X then a.X < b.X else a.Y < b.Y
end)

local SPOTS = kit.spots(kit.twinned(ordinary), kit.twinned({ JUNCTIONS.i + Vector2.new(8, -6) }))

local THEME: Theme = {
	ground = Enum.Material.Ground,
	ground_patches = Enum.Material.Sand,
	slope = Enum.Material.Rock,
	cliff = Enum.Material.Sandstone,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = Enum.Material.Limestone,
	high_from = TOP - 4,
	colors = {
		[Enum.Material.Ground] = Color3.fromRGB(150, 104, 72),
		[Enum.Material.Sand] = Color3.fromRGB(184, 136, 96),
		[Enum.Material.Rock] = Color3.fromRGB(138, 96, 72),
		[Enum.Material.Sandstone] = Color3.fromRGB(164, 88, 56),
		[Enum.Material.Limestone] = Color3.fromRGB(186, 140, 100),
	},
	water_color = Color3.fromRGB(46, 90, 110),
	paint = nil,
}

return table.freeze({
	name = "canyons",
	display_name = "Canyons",
	description = "A maze of canyons through a tableland",
	source = "design",
	size = SIZE,
	build = build,
	starts = { WEST_START, -WEST_START },
	start_boxes = { kit.box_around(WEST_START, 46), kit.box_around(-WEST_START, 46) },
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = nil,
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	conditions = nil,
	-- Late afternoon in red rock country: a low gold sun that throws the canyons into shadow, and dust blowing off the
	-- tableland.
	atmosphere = {
		clock_time = 16.8,
		latitude = 30,
		brightness = 2.2,
		sun_color = Color3.fromRGB(64, 34, 10),
		ambient = Color3.fromRGB(100, 84, 78),
		outdoor_ambient = Color3.fromRGB(130, 108, 96),
		haze_color = Color3.fromRGB(210, 160, 120),
		decay_color = Color3.fromRGB(160, 104, 74),
		density = 0.3,
		haze = 1.6,
		glare = 0.5,
		saturation = 0.1,
		weather = "dust",
		weather_amount = 0.45,
	},
} :: Preset)
