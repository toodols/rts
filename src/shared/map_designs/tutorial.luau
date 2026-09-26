--!strict
-- Tutorial: the campaign's first mission, a small valley split by a ridge with one narrow pass through it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local kit = require(script.Parent.kit)
local themes = require(script.Parent.themes)

local smoothstep = kit.smoothstep
local box_around = kit.box_around

type Preset = map_types.Preset
type Theme = map_types.Theme
type FixedMetalSpot = map_types.FixedMetalSpot
type FixedReclaimable = map_types.FixedReclaimable

local DEFAULT_WATER = themes.DEFAULT_WATER

-- The campaign's first mission (see server/missions/tutorial.luau), which finds its places here by name (`points`). A
-- small green valley, cut in two from edge to edge by a rocky ridge running north to south, with the player's side to the west
-- and the enemy's to the east. The ridge's faces are cliffs far steeper than anything walks (54 degrees is the most
-- anything can; these are about 80), and the only way through it is one narrow pass across its middle at z = 0, which
-- the tutorial's boulder fills (44 studs across, where the pass floor is 20 and its walls rise to the ridge within 6
-- more each side). Gentle hills rise at the map's edges to frame it. It is all dry: the commander wades any water, so
-- water would be no wall.
local TUTORIAL_SIZE = Vector2.new(320, 208)
local TUTORIAL_GROUND = 4
local TUTORIAL_HILLS = 1.2
local TUTORIAL_HILL_FREQUENCY = 0.025
-- The ridge's top, how far its top reaches either side of x = 0, give or take its warp, and how far out from there its
-- cliff falls to the valley floor.
local TUTORIAL_RIDGE_TOP = 34
local TUTORIAL_RIDGE_HALF = 26
local TUTORIAL_RIDGE_WARP = 4
local TUTORIAL_RIDGE_WARP_FREQUENCY = 0.035
local TUTORIAL_CLIFF = 6
local TUTORIAL_CRAGS = 5
local TUTORIAL_CRAG_FREQUENCY = 0.09
-- The pass: its floor is this far either side of z = 0, and its walls rise to the ridge's top over this much more.
local TUTORIAL_PASS_HALF = 10
local TUTORIAL_PASS_WALL = 6
-- The hills round the edge: how far in from the edge they reach and how high they rise, gently enough to walk up.
local TUTORIAL_RIM_REACH = 22
local TUTORIAL_RIM_TOP = 14
-- The starts, the middle of the pass, where the tutorial's boulder stands, and where its guide first sends the
-- commander, beside a metal spot, since extractors are built next.
local TUTORIAL_PLAYER_START = Vector2.new(-110, 0)
local TUTORIAL_ENEMY_START = Vector2.new(110, 0)
local TUTORIAL_PASS = Vector2.new(0, 0)
local TUTORIAL_FIRST_MOVE = Vector2.new(-82, -38)

local function tutorial_build(seed: number): (number, number) -> number
	local half_x = TUTORIAL_SIZE.X / 2
	local half_z = TUTORIAL_SIZE.Y / 2
	return function(x: number, z: number): number
		local hills = math.noise(x * TUTORIAL_HILL_FREQUENCY, z * TUTORIAL_HILL_FREQUENCY, seed + 2.3) * TUTORIAL_HILLS
		local from_edge = math.min(half_x - math.abs(x), half_z - math.abs(z))
		local rim = smoothstep((TUTORIAL_RIM_REACH - from_edge) / TUTORIAL_RIM_REACH) * TUTORIAL_RIM_TOP
		local floor = TUTORIAL_GROUND + hills + rim

		local warp = math.noise(z * TUTORIAL_RIDGE_WARP_FREQUENCY, 0.5, seed + 8.8) * TUTORIAL_RIDGE_WARP
		local ridge = smoothstep((TUTORIAL_RIDGE_HALF + warp + TUTORIAL_CLIFF - math.abs(x)) / TUTORIAL_CLIFF)
		local pass = smoothstep((math.abs(z) - TUTORIAL_PASS_HALF) / TUTORIAL_PASS_WALL)
		local crags = math.noise(x * TUTORIAL_CRAG_FREQUENCY, z * TUTORIAL_CRAG_FREQUENCY, seed + 4.1) * TUTORIAL_CRAGS
		return floor + (TUTORIAL_RIDGE_TOP + crags - floor) * ridge * pass
	end
end

-- A meadow: bright grass, bare rock on the ridge, and a dirt track through the pass.
local MEADOW: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.LeafyGrass,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Slate,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = Enum.Material.Rock,
	high_from = TUTORIAL_GROUND + TUTORIAL_RIM_TOP + 2,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(110, 150, 70),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(92, 134, 60),
		[Enum.Material.Ground] = Color3.fromRGB(128, 108, 80),
		[Enum.Material.Slate] = Color3.fromRGB(100, 98, 102),
		[Enum.Material.Rock] = Color3.fromRGB(122, 118, 110),
	},
	water_color = DEFAULT_WATER,
	paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
		return function(x: number, z: number, _height: number, too_steep: boolean): Enum.Material?
			local through_pass = math.abs(x) < TUTORIAL_RIDGE_HALF + TUTORIAL_CLIFF + 10
				and math.abs(z) < TUTORIAL_PASS_HALF - 1
			if through_pass and too_steep == false then
				return Enum.Material.Ground
			end
			return nil
		end
	end,
}

-- Every spot has its twin across the middle, so neither side has more.
local TUTORIAL_METAL: { FixedMetalSpot } = {}
for _, at in { Vector2.new(-124, -48), Vector2.new(-124, 48), Vector2.new(-72, -56) } do
	table.insert(TUTORIAL_METAL, { position = at, multiplier = nil })
	table.insert(TUTORIAL_METAL, { position = -at, multiplier = nil })
end

-- A few trees on the hills at the edge and some stones by the mouths of the pass, each with its twin across the middle,
-- holding what their defs say.
local function tutorial_reclaimables(): { FixedReclaimable }
	local laid: { { def_name: string, at: Vector2 } } = {
		{ def_name = "tree", at = Vector2.new(-146, -86) },
		{ def_name = "tree", at = Vector2.new(-134, -92) },
		{ def_name = "tree", at = Vector2.new(-150, -72) },
		{ def_name = "tree", at = Vector2.new(-96, -92) },
		{ def_name = "tree", at = Vector2.new(-148, 84) },
		{ def_name = "tree", at = Vector2.new(-70, 92) },
		{ def_name = "tree", at = Vector2.new(-58, 88) },
		{ def_name = "shrub", at = Vector2.new(-90, 70) },
		{ def_name = "shrub", at = Vector2.new(-150, 20) },
		{ def_name = "small_rock", at = Vector2.new(-46, 26) },
		{ def_name = "small_rock", at = Vector2.new(-52, -24) },
		{ def_name = "rock", at = Vector2.new(-44, -36) },
	}
	local out: { FixedReclaimable } = {}
	for index, each in laid do
		for _, at in { each.at, -each.at } do
			table.insert(out, {
				def_name = each.def_name,
				position = at,
				facing = index * 1.3,
				-- what the defs hold (unit_defs/reclaimable.luau)
				metal = unit_defs.get(each.def_name).metal_cost,
				energy = unit_defs.get(each.def_name).energy_cost,
				buildpower = unit_defs.get(each.def_name).buildpower_cost,
			})
		end
	end
	return out
end

return table.freeze({
	name = "tutorial",
	display_name = "Tutorial",
	source = "design",
	description = "A valley split by a ridge",
	build = tutorial_build,
	size = TUTORIAL_SIZE,
	-- the player's side is the odd slots and the enemy's the even ones
	starts = { TUTORIAL_PLAYER_START, TUTORIAL_ENEMY_START },
	start_boxes = { box_around(TUTORIAL_PLAYER_START, 36), box_around(TUTORIAL_ENEMY_START, 36) },
	metal_layers = nil,
	metal_spots = TUTORIAL_METAL,
	reclaimables = tutorial_reclaimables,
	theme = MEADOW,
	campaign_only = true,
	points = {
		player_start = TUTORIAL_PLAYER_START,
		enemy_start = TUTORIAL_ENEMY_START,
		pass = TUTORIAL_PASS,
		first_move = TUTORIAL_FIRST_MOVE,
	},
	-- A calm, sunny late morning in the valley, with nothing in the way of learning the game.
	atmosphere = {
		clock_time = 11,
		latitude = 25,
		brightness = 2.3,
		haze_color = Color3.fromRGB(150, 175, 200),
		decay_color = Color3.fromRGB(104, 128, 150),
		density = 0.28,
		haze = 1.2,
	},
} :: Preset)
