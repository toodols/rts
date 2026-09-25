-- Pinwheel: made for a free for all. Four arms of land spiral out from a hub in the middle to a rim of land round the
-- edge, and between each two a lake spirals the same way, so the map turns like a pinwheel and every arm is the same
-- as the others turned a quarter. Each arm has two starts, one out toward the rim and one in toward the hub, so it
-- seats eight; every start has land to one side, toward the hub and the rim, and a lake to the other, shared with the
-- arm next to it. The hub holds the richest metal, and every way from one arm to another on land goes through it or
-- round the rim.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

type Preset = map_types.Preset
type Theme = map_types.Theme
type StartBox = map_types.StartBox

local SIZE = Vector2.new(896, 896)
local LAND = 6
local LAKE = -7
local ROLL = 1.4
local ROLL_FREQUENCY = 0.018
local NOISE = 113.9
-- The arms: how far they turn, in radians, for every stud further out, and how much of the way round from one to the
-- next they take, as a share of a lake's width: over 0 is more land than lake. SHORE is about how many studs the coast
-- takes to fall from land to lake, the same near the hub as out by the rim.
local TWIST = 1 / 250
local ARM_SHARE = 0.2
local SHORE = 36
-- The hub, and the rim round the edge: land within HUB_RADIUS of the middle and beyond RIM_RADIUS, each falling to the
-- lakes over COAST studs.
local HUB_RADIUS = 104
local RIM_RADIUS = 392
local COAST = 26

-- Where the middle of an arm is at `radius` out: the angle it has turned to, for the first arm; the others are a
-- quarter, a half and three quarters of the way round from it.
local function arm_angle(radius: number): number
	return radius * TWIST
end

-- A point `radius` out along the middle of the first arm, turned `offset` radians further round.
local function on_arm(radius: number, offset: number): Vector2
	local angle = arm_angle(radius) + offset
	return Vector2.new(math.cos(angle), math.sin(angle)) * radius
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local radius = math.sqrt(x * x + z * z)
		local angle = math.atan2(z, x)
		-- 1 in the middle of an arm, -1 in the middle of a lake
		local arm = math.cos(4 * (angle - arm_angle(radius)))
		-- the arm's field changes by about 4 / radius for every stud round, so this is SHORE studs of it at any radius
		local across = SHORE * 4 / math.max(radius, 40)
		local land = kit.smoothstep((arm + ARM_SHARE) / across + 0.5)
		land = math.max(land, kit.falloff(radius, HUB_RADIUS - COAST, HUB_RADIUS))
		land = math.max(land, kit.smoothstep((radius - RIM_RADIUS + COAST) / COAST))
		return kit.lerp(LAKE, LAND, land) + kit.quarter_noise(x, z, ROLL_FREQUENCY, NOISE + seed) * ROLL
	end
end

-- The first arm's starts; the others' are them turned.
local OUTER_START = on_arm(300, 0)
local INNER_START = on_arm(180, 0)

local function turned(at: Vector2, quarters: number): Vector2
	local out = at
	for _ = 1, quarters do
		out = Vector2.new(-out.Y, out.X)
	end
	return out
end

-- The outer starts first, across from each other in pairs, so that two players are on opposite arms and four on one arm
-- each; then the inner ones in the same order.
local STARTS: { Vector2 } = {}
for _, start in { OUTER_START, INNER_START } do
	for _, quarters in { 0, 2, 1, 3 } do
		table.insert(STARTS, turned(start, quarters))
	end
end
local BOXES: { StartBox } = {}
for index, start in STARTS do
	table.insert(BOXES, kit.box_around(start, if index <= 4 then 44 else 36))
end

local SPOTS = kit.spots(
	kit.quartered({
		-- by the outer start
		on_arm(300, 0.12),
		on_arm(300, -0.12),
		on_arm(346, 0.05),
		on_arm(254, -0.08),
		-- by the inner start
		on_arm(206, 0.14),
		on_arm(150, -0.12),
		-- on the rim
		Vector2.new(360, 360),
		on_arm(420, 0.5),
		-- in the lake ahead of the arm
		on_arm(260, math.pi / 4),
	}),
	kit.quartered({ Vector2.new(46, 18) })
)

-- A vent beside every outer start.
local VENTS = kit.quartered({ on_arm(330, -0.1) })

local THEME: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.LeafyGrass,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Rock,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = nil,
	high_from = nil,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(100, 138, 64),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(80, 120, 54),
		[Enum.Material.Ground] = Color3.fromRGB(122, 102, 74),
		[Enum.Material.Sand] = Color3.fromRGB(210, 192, 146),
		[Enum.Material.Rock] = Color3.fromRGB(106, 102, 96),
	},
	water_color = Color3.fromRGB(36, 94, 122),
	paint = nil,
}

return table.freeze({
	name = "pinwheel",
	description = "Four spiral arms, for a free for all",
	size = SIZE,
	build = build,
	start_position = function(slot: number): Vector2
		return STARTS[(slot - 1) % 4 + 1]
	end,
	start_boxes = BOXES,
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = VENTS,
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	conditions = nil,
	-- A bright spring morning over the lakes, clear and a little more colourful than usual.
	atmosphere = {
		clock_time = 11.5,
		latitude = 35,
		brightness = 2.4,
		haze_color = Color3.fromRGB(150, 180, 210),
		decay_color = Color3.fromRGB(104, 134, 164),
		density = 0.28,
		haze = 1,
		saturation = 0.1,
	},
} :: Preset)
