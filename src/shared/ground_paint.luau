-- What the ground is made of at each place on a map, from the map preset's theme (see map_presets.luau). The ground is
-- painted by what can cross it, with the limits passability uses: one material where tanks can drive, another where
-- only bots can climb, and a third where nothing walks. So a player reads the routes off the colour of the ground, and
-- a crater's walls turn to rock as they steepen.
--
-- The server's terrain is painted with this, and so is the lobby's picture of each map, so the two agree.

local config = require(script.Parent.config)
local map_presets = require(script.Parent.map_presets)
local passability = require(script.Parent.passability)

type Theme = map_presets.Theme

export type Painter = (x: number, z: number, height: number, steepness: number) -> Enum.Material

-- The steepest ground a tank, and then a bot, can stand on, as rise over run.
local TANK_STEEPNESS = passability.steepness_limit(passability.max_slope "TANK2" :: number)
local BOT_STEEPNESS = passability.steepness_limit(passability.max_slope "BOT2" :: number)
-- Ground within this much of the waterline, either side, is the shore.
local SHORE_BAND = 1.5
-- The size of the patches the ground is mottled with, and how much of it they cover: noise runs from about
-- -0.5 to 0.5, so above 0.15 is roughly a third.
local PATCH_FREQUENCY = 0.035
local PATCH_THRESHOLD = 0.15
-- Where the high ground begins wavers by this much, so the snowline is not drawn with a ruler.
local HIGH_GROUND_WAVER = 3
local HIGH_GROUND_FREQUENCY = 0.05

-- What each material looks like where a theme does not give it a colour of its own: Roblox's own terrain colours.
local MATERIAL_COLORS: { [Enum.Material]: Color3 } = {
	[Enum.Material.Grass] = Color3.fromRGB(106, 127, 63),
	[Enum.Material.LeafyGrass] = Color3.fromRGB(115, 132, 74),
	[Enum.Material.Ground] = Color3.fromRGB(102, 92, 59),
	[Enum.Material.Mud] = Color3.fromRGB(58, 46, 36),
	[Enum.Material.Sand] = Color3.fromRGB(143, 126, 95),
	[Enum.Material.Sandstone] = Color3.fromRGB(137, 90, 71),
	[Enum.Material.Limestone] = Color3.fromRGB(206, 173, 148),
	[Enum.Material.Rock] = Color3.fromRGB(102, 108, 111),
	[Enum.Material.Slate] = Color3.fromRGB(63, 127, 107),
	[Enum.Material.Basalt] = Color3.fromRGB(30, 30, 37),
	[Enum.Material.CrackedLava] = Color3.fromRGB(232, 156, 74),
	[Enum.Material.Salt] = Color3.fromRGB(198, 189, 181),
	[Enum.Material.Snow] = Color3.fromRGB(195, 199, 218),
	[Enum.Material.Glacier] = Color3.fromRGB(101, 176, 234),
	[Enum.Material.Ice] = Color3.fromRGB(129, 194, 224),
	[Enum.Material.Pavement] = Color3.fromRGB(148, 148, 140),
	[Enum.Material.Asphalt] = Color3.fromRGB(115, 123, 107),
	[Enum.Material.Concrete] = Color3.fromRGB(127, 102, 63),
	[Enum.Material.Cobblestone] = Color3.fromRGB(132, 123, 90),
	[Enum.Material.Brick] = Color3.fromRGB(138, 86, 62),
	[Enum.Material.WoodPlanks] = Color3.fromRGB(139, 109, 79),
}
local UNKNOWN_COLOR = Color3.fromRGB(110, 110, 110)

local function make_painter(theme: Theme, seed: number): Painter
	local special = if theme.paint ~= nil then theme.paint(seed) else nil
	return function(x: number, z: number, height: number, steepness: number): Enum.Material
		local too_steep = steepness > BOT_STEEPNESS
		if special ~= nil then
			local material = special(x, z, height, too_steep)
			if material ~= nil then
				return material
			end
		end
		if too_steep then
			return theme.cliff
		end
		if height < config.WATER_LEVEL - SHORE_BAND then
			return theme.seabed
		end
		if height < config.WATER_LEVEL + SHORE_BAND then
			return theme.shore
		end
		if steepness > TANK_STEEPNESS then
			return theme.slope
		end
		if theme.high_ground ~= nil and theme.high_from ~= nil then
			local waver = math.noise(x * HIGH_GROUND_FREQUENCY, z * HIGH_GROUND_FREQUENCY, seed + 17.3)
			if height > theme.high_from + waver * HIGH_GROUND_WAVER then
				return theme.high_ground
			end
		end
		if math.noise(x * PATCH_FREQUENCY, z * PATCH_FREQUENCY, seed + 51.9) > PATCH_THRESHOLD then
			return theme.ground_patches
		end
		return theme.ground
	end
end

-- The colour `material` is drawn in on a map with `theme`.
local function color_of(theme: Theme, material: Enum.Material): Color3
	local own = theme.colors[material]
	if own ~= nil then
		return own
	end
	return MATERIAL_COLORS[material] or UNKNOWN_COLOR
end

return table.freeze({
	make_painter = make_painter,
	color_of = color_of,
})
