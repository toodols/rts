--!strict
-- Trenches: two long ridges face each other across a sunken no man's land, one in front of each side's base. Behind
-- its own ridge a side is out of sight and out of direct fire, and from the crest it looks down on the ground between;
-- to reach the other side's base, shells have to arc over the ridge, so it is plasma artillery against shields. The
-- ground between holds the richest metal, open to fire from both crests, and every shell that falls on it leaves its
-- crater.
--
-- Each ridge's back slope is gentle enough to drive up, and its front is steep enough that only bots climb it. It is
-- broken by two gaps, north and south, which are the ways through for anything that drives.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

type Preset = map_types.Preset
type Theme = map_types.Theme

local SIZE = Vector2.new(768, 768)
local GROUND = 6
local LOW = 2.5
local ROLL = 1.0
local ROLL_FREQUENCY = 0.02
local NOISE = 71.9
-- The ridge's crest, how far out from x = 0 its middle is, and how far either side of that it is level; its front falls
-- to no man's land over FRONT studs and its back to the ground behind over BACK.
local CREST = 24
local CREST_X = 104
local CREST_HALF_WIDTH = 5
local FRONT = 30
local BACK = 64
-- How far the crest's line wanders east and west along its length.
local CREST_WANDER = 8
local CREST_WANDER_FREQUENCY = 0.012
-- The gaps: their middle, and how far either side of it they are open and how far more their sides take to rise.
local GAP_Z = 190
local GAP_HALF_WIDTH = 14
local GAP_SIDE = 26

-- How much of the way up its ridge (x, z) is, before the gaps.
local function ridge(x: number, z: number): number
	-- the east ridge wanders as the west one does, turned half way round the middle
	local wander = kit.noise(0.5, if x < 0 then z else -z, CREST_WANDER_FREQUENCY, NOISE + 3.3) * CREST_WANDER
	local out = math.abs(x) - CREST_X - wander
	if out < -CREST_HALF_WIDTH then
		return kit.smoothstep((FRONT + out + CREST_HALF_WIDTH) / FRONT)
	elseif out > CREST_HALF_WIDTH then
		return kit.smoothstep((BACK - out + CREST_HALF_WIDTH) / BACK)
	end
	return 1
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local roll = kit.twin_noise(x, z, ROLL_FREQUENCY, NOISE + seed) * ROLL
		-- the base ground behind the ridges, and no man's land sunk between them
		local between = kit.smoothstep((CREST_X - math.abs(x)) / 40)
		local floor = kit.lerp(GROUND, LOW, between) + roll
		local gap = kit.smoothstep((math.abs(math.abs(z) - GAP_Z) - GAP_HALF_WIDTH) / GAP_SIDE)
		return kit.lerp(floor, CREST + roll, ridge(x, z) * gap)
	end
end

local WEST_START = Vector2.new(-300, 0)

local SPOTS = kit.spots(
	kit.twinned({
		-- home
		Vector2.new(-330, -46),
		Vector2.new(-330, 46),
		Vector2.new(-280, -86),
		Vector2.new(-280, 86),
		Vector2.new(-318, -180),
		Vector2.new(-318, 180),
		Vector2.new(-300, -310),
		Vector2.new(-300, 310),
		-- behind the ridge
		Vector2.new(-190, -90),
		Vector2.new(-190, 90),
		Vector2.new(-200, -270),
		Vector2.new(-200, 270),
		-- no man's land
		Vector2.new(-30, -260),
		Vector2.new(-30, 260),
		Vector2.new(-40, -140),
	}),
	kit.twinned({ Vector2.new(-24, 40), Vector2.new(0, -330) })
)

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
		[Enum.Material.Grass] = Color3.fromRGB(100, 120, 66),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(86, 106, 58),
		[Enum.Material.Ground] = Color3.fromRGB(118, 98, 74),
		[Enum.Material.Mud] = Color3.fromRGB(96, 82, 64),
		[Enum.Material.Rock] = Color3.fromRGB(104, 100, 94),
	},
	water_color = Color3.fromRGB(56, 76, 84),
	-- no man's land is churned to mud
	paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
		return function(x: number, _z: number, height: number, too_steep: boolean): Enum.Material?
			if too_steep == false and math.abs(x) < CREST_X - 20 and height < LOW + 2.5 then
				return Enum.Material.Mud
			end
			return nil
		end
	end,
}

return table.freeze({
	name = "trenches",
	display_name = "Trenches",
	description = "Two ridges and a no man's land",
	source = "design",
	size = SIZE,
	build = build,
	starts = { WEST_START, -WEST_START },
	start_boxes = { kit.box_around(WEST_START, 58), kit.box_around(-WEST_START, 58) },
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = nil,
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	conditions = nil,
	-- Rain over no man's land, the colour washed out of it and a smoky mist lying in the low ground.
	atmosphere = {
		clock_time = 11.5,
		brightness = 1.7,
		exposure = -0.05,
		ambient = Color3.fromRGB(112, 116, 116),
		outdoor_ambient = Color3.fromRGB(138, 142, 144),
		haze_color = Color3.fromRGB(136, 142, 140),
		decay_color = Color3.fromRGB(100, 106, 104),
		density = 0.4,
		haze = 2.4,
		glare = 0,
		saturation = -0.25,
		contrast = 0.05,
		weather = "rain",
		weather_amount = 0.9,
		tint = Color3.fromRGB(224, 228, 230),
		mist = 0.5,
		mist_color = Color3.fromRGB(170, 168, 160),
	},
} :: Preset)
