--!strict
-- Highlands: rolling hills with basins that dip below the sea in places, generated from the seed, and the same for
-- both sides: its ground, starts and metal are turned half round about the middle (`kit.point_symmetric`,
-- `Preset.symmetric`), so that neither start box is better off than the other.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)
local themes = require(script.Parent.themes)

type Preset = map_types.Preset
type StartBox = map_types.StartBox

local SIZE = kit.GENERATED_SIZE
local HALF_X = SIZE.X / 2
local HALF_Z = SIZE.Y / 2
-- Gentle relief, so that plenty of the ground is flat enough to build on.
local AMPLITUDE = 9
local FREQUENCY = 0.012
-- Broad basins laid under the hills, wide and deep enough to take the ground below sea level.
local BASIN_AMPLITUDE = 14
local BASIN_FREQUENCY_FACTOR = 0.35

local function build(seed: number): (number, number) -> number
	local frequency = FREQUENCY
	local basin_frequency = frequency * BASIN_FREQUENCY_FACTOR
	return function(world_x: number, world_z: number): number
		-- the noise is laid out from the map corner, not its middle
		local x = world_x + HALF_X
		local z = world_z + HALF_Z
		local coarse = math.noise(x * frequency, z * frequency, seed)
		local fine = math.noise(x * frequency * 4, z * frequency * 4, seed + 13.7)
		local basin = math.noise(x * basin_frequency, z * basin_frequency, seed + 29.1)
		return ground_levels.TERRAIN_BASE_HEIGHT + (coarse + fine * 0.25) * AMPLITUDE + basin * BASIN_AMPLITUDE
	end
end

-- A strip down each of the east and west sides, each taking in the start there, well clear of the middle.
local BOXES: { StartBox } = {
	{ min = Vector2.new(140, -200), max = Vector2.new(HALF_X - 24, 200) },
	{ min = Vector2.new(-(HALF_X - 24), -200), max = Vector2.new(-140, 200) },
}

return table.freeze({
	name = "highlands",
	display_name = "Highlands",
	description = "Rolling hills and sunken basins",
	source = "generated",
	size = SIZE,
	build = kit.point_symmetric(build),
	symmetric = true,
	starts = kit.ring_starts(kit.RING_RADIUS),
	start_boxes = BOXES,
	metal_layers = nil,
	metal_spots = nil,
	theme = themes.TEMPERATE,
	-- A fresh morning in the hills, a little blue in the distance, with a thin mist still lying in the basins.
	atmosphere = {
		clock_time = 10.5,
		latitude = 35,
		brightness = 2.2,
		haze_color = Color3.fromRGB(150, 170, 190),
		decay_color = Color3.fromRGB(100, 120, 140),
		density = 0.3,
		haze = 1.2,
		saturation = 0.05,
		mist = 0.3,
		mist_color = Color3.fromRGB(214, 222, 228),
	},
} :: Preset)
