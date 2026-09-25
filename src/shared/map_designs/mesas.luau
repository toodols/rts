-- Mesas: a desert floor with tall, flat-topped mesas standing out of it, their sides sheer all the way round, so that
-- nothing that walks or drives can get up one. Their tops hold the rich metal, and the one in the middle a vent as
-- well, for whoever carries a builder up there, or flies one: a transport, or an aircraft that builds. Once up, a mesa
-- is a fortress, and the only way to take it back is from the air.
--
-- The floor has plenty of ordinary metal of its own, and the mesas stand in the way of the view across it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

type Preset = map_types.Preset
type Theme = map_types.Theme

local SIZE = Vector2.new(768, 768)
local FLOOR = 5
-- Dunes on the floor, and a slight roughness to the mesas' tops.
local DUNES = 1.6
local DUNE_FREQUENCY = 0.018
local TOP_ROUGHNESS = 0.4
local TOP = 46
-- A mesa's side falls from the edge of its top over WALL studs, far steeper than anything climbs, and ends in a skirt of
-- scree SCREE studs further out, which takes SCREE_SHARE of the drop. How far its edge wanders in and out, as a share of
-- its radius.
local WALL = 7
local SCREE = 12
local SCREE_SHARE = 0.12
local EDGE_WANDER = 0.1
local EDGE_WANDER_FREQUENCY = 0.045
local NOISE = 57.3

type Mesa = { center: Vector2, radius: number }

-- One side's mesas, each with its twin across the middle, and the great one in the middle.
local MESAS: { Mesa } = {}
for _, mesa in
	{
		{ center = Vector2.new(-150, -190), radius = 40 },
		{ center = Vector2.new(-170, 150), radius = 34 },
		{ center = Vector2.new(-30, -300), radius = 30 },
		{ center = Vector2.new(-60, 170), radius = 26 },
	} :: { Mesa }
do
	table.insert(MESAS, mesa)
	table.insert(MESAS, { center = -mesa.center, radius = mesa.radius })
end
table.insert(MESAS, { center = Vector2.zero, radius = 62 })

-- How far up a mesa (x, z) is: 1 on its top, 0 on the floor beyond its scree.
local function up(mesa: Mesa, x: number, z: number, wander: number): number
	local distance = (Vector2.new(x, z) - mesa.center).Magnitude
	local edge = mesa.radius * (1 + wander * EDGE_WANDER)
	local wall = kit.smoothstep((edge + WALL - distance) / WALL)
	local scree = kit.smoothstep((edge + WALL + SCREE - distance) / (WALL + SCREE))
	return wall * (1 - SCREE_SHARE) + scree * SCREE_SHARE
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local floor = FLOOR + kit.twin_noise(x, z, DUNE_FREQUENCY, NOISE + seed) * DUNES
		local top = TOP + kit.twin_noise(x, z, 0.05, NOISE + 1.3 + seed) * TOP_ROUGHNESS
		-- the same wander for a mesa and its twin, so that neither is bigger
		local wander = kit.twin_noise(x, z, EDGE_WANDER_FREQUENCY, NOISE + 2.9)
		local rise = 0
		for _, mesa in MESAS do
			rise = math.max(rise, up(mesa, x, z, wander))
		end
		return kit.lerp(floor, top, rise)
	end
end

local WEST_START = Vector2.new(-310, 0)

-- Two rich spots on every mesa but the smallest, which has one, and four on the one in the middle.
local rich: { Vector2 } = {
	Vector2.new(-162, -200),
	Vector2.new(-138, -178),
	Vector2.new(-180, 142),
	Vector2.new(-160, 158),
	Vector2.new(-30, -300),
	Vector2.new(-60, 170),
	Vector2.new(-30, -26),
	Vector2.new(-30, 26),
}

local SPOTS = kit.spots(
	kit.twinned({
		-- home
		Vector2.new(-340, -44),
		Vector2.new(-340, 44),
		Vector2.new(-290, -86),
		Vector2.new(-290, 86),
		Vector2.new(-326, -170),
		Vector2.new(-326, 170),
		Vector2.new(-250, -290),
		Vector2.new(-250, 290),
		-- out on the floor
		Vector2.new(-220, -60),
		Vector2.new(-206, 60),
		Vector2.new(-90, -100),
		Vector2.new(-110, 60),
		Vector2.new(-130, 300),
		Vector2.new(60, -250),
	}),
	kit.twinned(rich)
)

local THEME: Theme = {
	ground = Enum.Material.Sand,
	ground_patches = Enum.Material.Sandstone,
	slope = Enum.Material.Sandstone,
	cliff = Enum.Material.Sandstone,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = Enum.Material.Limestone,
	high_from = TOP - 3,
	colors = {
		[Enum.Material.Sand] = Color3.fromRGB(206, 164, 112),
		[Enum.Material.Sandstone] = Color3.fromRGB(176, 102, 66),
		[Enum.Material.Limestone] = Color3.fromRGB(196, 150, 104),
		[Enum.Material.Ground] = Color3.fromRGB(160, 116, 78),
	},
	water_color = Color3.fromRGB(46, 90, 110),
	paint = nil,
}

return table.freeze({
	name = "mesas",
	description = "Desert mesas with rich metal on top",
	size = SIZE,
	build = build,
	start_position = function(slot: number): Vector2
		return if slot % 2 == 1 then WEST_START else -WEST_START
	end,
	start_boxes = { kit.box_around(WEST_START, 58), kit.box_around(-WEST_START, 58) },
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = { Vector2.new(0, 0) },
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	conditions = nil,
	-- Desert noon: a hard white sun overhead, heat haze, and dust and sand blowing across the floor in gusts.
	atmosphere = {
		clock_time = 12.8,
		latitude = 15,
		brightness = 2.8,
		exposure = -0.05,
		ambient = Color3.fromRGB(110, 96, 84),
		outdoor_ambient = Color3.fromRGB(140, 122, 104),
		haze_color = Color3.fromRGB(220, 190, 150),
		decay_color = Color3.fromRGB(180, 140, 100),
		density = 0.32,
		haze = 2,
		glare = 0.4,
		tint = Color3.fromRGB(255, 246, 232),
		weather = "dust",
		weather_amount = 1,
	},
} :: Preset)
