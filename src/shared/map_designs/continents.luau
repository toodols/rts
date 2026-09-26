--!strict
-- Continents: two continents side by side, joined by two narrow land bridges, with sea all around, generated from the
-- seed.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)
local themes = require(script.Parent.themes)

type Preset = map_types.Preset
type StartBox = map_types.StartBox

local SEA_FLOOR = kit.SEA_FLOOR
local CENTER_X = 185
local HALF_X = 150
local HALF_Z = 300
local TOP = 6
-- How much of the way in from the coast the ground takes to reach its full height, as a fraction of the radius.
local SHORE = 0.35
local HILLS = 2.5
local HILL_FREQUENCY = 0.02
-- The bridges run between the continents at these z, each this wide from its middle to one bank.
local BRIDGE_Z = 230
local BRIDGE_HALF_WIDTH = 18
local BRIDGE_TOP = 5
local BRIDGE_BANK = 0.5
local COAST_WARP = 0.08

-- Teams stand on the far ends of the continents, alternating between the two so that slots 1 and 2, then 3
-- and 4, face each other across the water.
local START_Z = 110
local STARTS = {
	Vector2.new(CENTER_X, -START_Z),
	Vector2.new(-CENTER_X, START_Z),
	Vector2.new(CENTER_X, START_Z),
	Vector2.new(-CENTER_X, -START_Z),
}

-- The heart of each continent, far enough in from its coast that the whole box is dry.
local BOXES: { StartBox } = {
	{ min = Vector2.new(CENTER_X - 100, -200), max = Vector2.new(CENTER_X + 100, 200) },
	{ min = Vector2.new(-CENTER_X - 100, -200), max = Vector2.new(-CENTER_X + 100, 200) },
}

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local warp = 1 + math.noise(x * kit.COAST_FREQUENCY, z * kit.COAST_FREQUENCY, seed + 5.5) * COAST_WARP
		local dx = (math.abs(x) - CENTER_X) / HALF_X
		local dz = z / HALF_Z
		local land = kit.smoothstep((1 - math.sqrt(dx * dx + dz * dz) * warp) / SHORE)
		local hills = math.noise(x * HILL_FREQUENCY, z * HILL_FREQUENCY, seed + 9.1)
		local height = SEA_FLOOR + (TOP + hills * HILLS - SEA_FLOOR) * land

		-- a bridge only exists between the continents
		if math.abs(x) < CENTER_X then
			local across = math.abs(math.abs(z) - BRIDGE_Z)
			local bridge = kit.smoothstep((BRIDGE_HALF_WIDTH - across) / (BRIDGE_HALF_WIDTH * BRIDGE_BANK))
			height = math.max(height, SEA_FLOOR + (BRIDGE_TOP - SEA_FLOOR) * bridge)
		end
		return height + kit.ripple(x, z, seed)
	end
end

return table.freeze({
	name = "continents",
	display_name = "Continents",
	description = "Two continents, two land bridges",
	source = "generated",
	size = kit.GENERATED_SIZE,
	build = build,
	starts = STARTS,
	start_boxes = BOXES,
	metal_layers = nil,
	metal_spots = nil,
	theme = themes.TEMPERATE,
	-- Clear coastal midday, with a blue sea haze on the far shore.
	atmosphere = {
		clock_time = 12.5,
		latitude = 25,
		brightness = 2.4,
		outdoor_ambient = Color3.fromRGB(110, 122, 140),
		haze_color = Color3.fromRGB(130, 160, 190),
		decay_color = Color3.fromRGB(90, 120, 150),
		density = 0.28,
		haze = 1,
	},
} :: Preset)
