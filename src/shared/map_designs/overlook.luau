--!strict
-- Overlook: the campaign's second mission, a plateau whose cliff overlooks the low ground, with a ramp down at each end
-- and a road down its face between them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local kit = require(script.Parent.kit)
local tutorial = require(script.Parent.tutorial)

local smoothstep = kit.smoothstep
local box_around = kit.box_around

type Preset = map_types.Preset
type Theme = map_types.Theme
type FixedMetalSpot = map_types.FixedMetalSpot
type FixedReclaimable = map_types.FixedReclaimable

-- The tutorial's meadow, which this is the same country as.
local MEADOW: Theme = tutorial.theme

-- The campaign's second and third missions (see server/missions/overlook.luau and counterattack.luau), which find their
-- starts here by name (`points`) and the cliff's edge on the ground as it is built (mission_map.brink_x). The player's
-- side, to the west, is a plateau about OVERLOOK_DROP studs above the low ground to the east, where the enemy's
-- base is. Along most of its length the plateau ends in a cliff, which is what the player looks down on the base from:
-- a shell fired from up there carries further than its range on the level (projectile.range_to), so a thug at the edge
-- outshoots the guards below. Near the north and south edges of the map a ramp, gentle enough for any bot, winds down
-- from the plateau to the low ground between steep sides. Between them a road for vehicles, which cannot climb the
-- ramps, runs down along the cliff's face, from the edge at one end to the low ground at the other, heading out from
-- the face as it goes. Hills rise unevenly at the map's edges to frame it. It is all dry.
--
-- The cliff is drawn so as not to look built: its edge wanders, crags stand out of its face, and its foot runs out into
-- a skirt of scree, while the ground above and below rolls. The face is spread over OVERLOOK_FACE studs, so that it is
-- drawn as a slope of voxels rather than one sheer wall of them, and still far steeper than anything walks (54 degrees
-- is the most anything can; the face is about 75). None of it depends on the seed: the mission's enemy stands where it
-- does against this one cliff.
--
-- It is a small map, 152 by 128 studs: the plateau is some 60 studs deep and the low ground some 90, which is room for
-- the enemy's base behind what a thug at the edge can reach (see server/missions/overlook.luau) and not much more. The heights
-- are the weapons' business (a thug outranges a guard from up there by the drop), so they are what they would be on a
-- bigger map; only the lengths across it are small.
local OVERLOOK_SIZE = Vector2.new(152, 128)
local OVERLOOK_GROUND = 4
-- The noise every part of it is drawn from, in place of the seed.
local OVERLOOK_NOISE = 41.7
-- Rolling ground, above and below.
local OVERLOOK_HILLS = 1.5
local OVERLOOK_HILL_FREQUENCY = 0.03
-- The plateau: how far above the low ground it stands, and the x its edge wanders about, by as much as
-- OVERLOOK_EDGE_WANDER one way or the other over long stretches and a little more over short ones.
local OVERLOOK_DROP = 28
local OVERLOOK_EDGE_X = -18
local OVERLOOK_EDGE_WANDER = 3
local OVERLOOK_EDGE_WANDER_FREQUENCY = 0.04
local OVERLOOK_EDGE_JITTER = 1
local OVERLOOK_EDGE_JITTER_FREQUENCY = 0.09
-- The face: how far out from the edge it falls, how much of the drop the scree at its foot takes, over how much more,
-- and the crags, which push the face in and out by as much as OVERLOOK_CRAGS studs.
local OVERLOOK_FACE = 10
local OVERLOOK_SCREE = 0.12
local OVERLOOK_SCREE_RUN = 6
local OVERLOOK_CRAGS = 2
local OVERLOOK_CRAG_FREQUENCY = 0.14
-- The ramps, one each side of z = 0: the middle they wind about, how far either side of it they are a ramp and no
-- less, and how far more their steep sides take to rise to the cliff. Each runs down from the edge over
-- OVERLOOK_RAMP_RUN.
local OVERLOOK_RAMP_Z = 43
local OVERLOOK_RAMP_WIND = 3
local OVERLOOK_RAMP_WIND_FREQUENCY = 0.06
local OVERLOOK_RAMP_HALF = 6
local OVERLOOK_RAMP_SIDE = 5
local OVERLOOK_RAMP_RUN = 40
-- The road down the face, straight: where its middle leaves the plateau and where it reaches the low ground, in world
-- (x, z), how far either side of the middle it is road and no less, and how far more its outer side takes to fall to
-- the low ground. Its inner side is filled up to the face. It falls evenly along its length, the drop over some 72
-- studs, about 21 degrees, which a tank (27 at most) climbs with room to spare for the rolling ground.
local OVERLOOK_ROAD_TOP = Vector2.new(OVERLOOK_EDGE_X - 1, 33)
local OVERLOOK_ROAD_FOOT = Vector2.new(OVERLOOK_EDGE_X + 27, -34)
local OVERLOOK_ROAD_HALF = 6
local OVERLOOK_ROAD_SIDE = 10
-- The hills round the edge: how far in from the edge they reach, give or take, and how high they rise, gently enough
-- to walk up.
local OVERLOOK_RIM_REACH = 11
local OVERLOOK_RIM_WANDER = 4
local OVERLOOK_RIM_TOP = 6
-- The starts.
local OVERLOOK_PLAYER_START = Vector2.new(-53, 0)
local OVERLOOK_ENEMY_START = Vector2.new(42, 0)

local function overlook_noise(x: number, z: number, frequency: number, offset: number): number
	return math.noise(x * frequency, z * frequency, OVERLOOK_NOISE + offset)
end

-- The x the plateau's edge is at, at `z`, before the crags.
local function overlook_edge(z: number): number
	return OVERLOOK_EDGE_X
		+ overlook_noise(0.5, z, OVERLOOK_EDGE_WANDER_FREQUENCY, 1.1) * OVERLOOK_EDGE_WANDER * 2
		+ overlook_noise(0.5, z, OVERLOOK_EDGE_JITTER_FREQUENCY, 2.2) * OVERLOOK_EDGE_JITTER * 2
end

-- How far along the road (x, z) is, 0 at its top and 1 at its foot, and how far out from its middle, in studs: positive
-- on its outer side, away from the face, and negative on its inner side. The road is only where the first is between 0
-- and 1.
local function overlook_road(x: number, z: number): (number, number)
	local run = OVERLOOK_ROAD_FOOT - OVERLOOK_ROAD_TOP
	local from_top = Vector2.new(x, z) - OVERLOOK_ROAD_TOP
	local along = from_top:Dot(run) / run:Dot(run)
	-- the outward normal: the road runs towards -z, so east (+x, away from the face) is to its left
	local outward = Vector2.new(-run.Y, run.X).Unit
	return along, from_top:Dot(outward)
end

-- How much of the way up to the plateau the ground is at (x, z): 1 on it, 0 on the low ground.
local function overlook_plateau(x: number, z: number): number
	local edge = overlook_edge(z) + overlook_noise(x, z, OVERLOOK_CRAG_FREQUENCY, 3.3) * OVERLOOK_CRAGS
	local face = smoothstep((edge + OVERLOOK_FACE - x) / OVERLOOK_FACE)
	local scree = smoothstep((edge + OVERLOOK_FACE + OVERLOOK_SCREE_RUN - x) / (OVERLOOK_FACE + OVERLOOK_SCREE_RUN))
	local cliff = face * (1 - OVERLOOK_SCREE) + scree * OVERLOOK_SCREE

	local ramp = smoothstep((overlook_edge(z) + OVERLOOK_RAMP_RUN - x) / OVERLOOK_RAMP_RUN)
	local middle = OVERLOOK_RAMP_Z + overlook_noise(x, 0.5, OVERLOOK_RAMP_WIND_FREQUENCY, 4.4) * OVERLOOK_RAMP_WIND * 2
	local on_ramp =
		smoothstep((OVERLOOK_RAMP_HALF + OVERLOOK_RAMP_SIDE - math.abs(math.abs(z) - middle)) / OVERLOOK_RAMP_SIDE)

	-- the road falls evenly from the plateau's height at its top to the low ground's at its foot, filled in from the
	-- face on its inner side, and ends at its top as the face does, steeply
	local along, out = overlook_road(x, z)
	local on_road = smoothstep((OVERLOOK_ROAD_HALF + OVERLOOK_ROAD_SIDE - out) / OVERLOOK_ROAD_SIDE)
	local road = if along >= 0 and along <= 1 then (1 - along) * on_road else 0

	-- a ramp or the road only ever lifts the ground, so the plateau stays whole behind the edge
	return math.max(cliff, ramp * on_ramp, road)
end

local function overlook_build(_seed: number): (number, number) -> number
	local half_x = OVERLOOK_SIZE.X / 2
	local half_z = OVERLOOK_SIZE.Y / 2
	return function(x: number, z: number): number
		local hills = overlook_noise(x, z, OVERLOOK_HILL_FREQUENCY, 5.5) * OVERLOOK_HILLS * 2
		local from_edge = math.min(half_x - math.abs(x), half_z - math.abs(z))
		local reach = OVERLOOK_RIM_REACH + overlook_noise(x, z, OVERLOOK_HILL_FREQUENCY, 6.6) * OVERLOOK_RIM_WANDER * 2
		local rim = smoothstep((reach - from_edge) / reach) * OVERLOOK_RIM_TOP
		return OVERLOOK_GROUND + hills + rim + OVERLOOK_DROP * overlook_plateau(x, z)
	end
end

-- The meadow, with no rock on the plateau (it is high, but it is where the player builds), and a dirt track down each
-- ramp and the road so that the ways down read from above.
local OVERLOOK_THEME: Theme = table.clone(MEADOW)
OVERLOOK_THEME.high_ground = nil
OVERLOOK_THEME.high_from = nil
OVERLOOK_THEME.paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
	return function(x: number, z: number, _height: number, too_steep: boolean): Enum.Material?
		local middle = OVERLOOK_RAMP_Z
			+ overlook_noise(x, 0.5, OVERLOOK_RAMP_WIND_FREQUENCY, 4.4) * OVERLOOK_RAMP_WIND * 2
		local down_ramp = x > overlook_edge(z) - 7
			and x < overlook_edge(z) + OVERLOOK_RAMP_RUN + 5
			and math.abs(math.abs(z) - middle) < OVERLOOK_RAMP_HALF - 1
		local along, out = overlook_road(x, z)
		local down_road = along >= 0 and along <= 1 and math.abs(out) < OVERLOOK_ROAD_HALF - 1
		if (down_ramp or down_road) and too_steep == false then
			return Enum.Material.Ground
		end
		return nil
	end
end

-- Four spots on the plateau for the player, and two in the enemy's base, which it has extractors on from the start.
-- They are ordinary spots, on which an extractor makes 2 metal a second, so the player's four and their commander's 2
-- make the 10 a second the mission's guide asks for (client/missions/overlook.luau).
local OVERLOOK_METAL: { FixedMetalSpot } = {}
for _, at in
	{
		Vector2.new(-58, -24),
		Vector2.new(-58, 24),
		Vector2.new(-40, -35),
		Vector2.new(-40, 35),
		Vector2.new(58, -29),
		Vector2.new(58, 29),
	}
do
	table.insert(OVERLOOK_METAL, { position = at, multiplier = nil })
end

-- Trees on the plateau, and stones fallen from the cliff at its foot and at the feet of the ramps, holding what their
-- defs say.
local function overlook_reclaimables(): { FixedReclaimable }
	local laid: { { def_name: string, at: Vector2 } } = {
		{ def_name = "tree", at = Vector2.new(-70, -49) },
		{ def_name = "tree", at = Vector2.new(-64, -53) },
		{ def_name = "tree", at = Vector2.new(-71, -38) },
		{ def_name = "tree", at = Vector2.new(-68, 48) },
		{ def_name = "tree", at = Vector2.new(-60, 52) },
		{ def_name = "tree", at = Vector2.new(-71, 7) },
		{ def_name = "shrub", at = Vector2.new(-65, -10) },
		{ def_name = "shrub", at = Vector2.new(-32, -16) },
		{ def_name = "shrub", at = Vector2.new(-30, 18) },
		{ def_name = "small_rock", at = Vector2.new(-6, -13) },
		{ def_name = "small_rock", at = Vector2.new(-5, 18) },
		{ def_name = "rock", at = Vector2.new(-7, 2) },
		{ def_name = "small_rock", at = Vector2.new(17, -52) },
		{ def_name = "rock", at = Vector2.new(18, 53) },
	}
	local out: { FixedReclaimable } = {}
	for index, each in laid do
		table.insert(out, {
			def_name = each.def_name,
			position = each.at,
			facing = index * 1.3,
			-- what the defs hold (unit_defs/reclaimable.luau)
			metal = unit_defs.get(each.def_name).metal_cost,
			energy = unit_defs.get(each.def_name).energy_cost,
			buildpower = unit_defs.get(each.def_name).buildpower_cost,
		})
	end
	return out
end

return table.freeze({
	name = "overlook",
	display_name = "Overlook",
	source = "design",
	description = "A plateau over the low ground",
	build = overlook_build,
	size = OVERLOOK_SIZE,
	-- the player's side is the odd slots and the enemy's the even ones
	starts = { OVERLOOK_PLAYER_START, OVERLOOK_ENEMY_START },
	start_boxes = { box_around(OVERLOOK_PLAYER_START, 22), box_around(OVERLOOK_ENEMY_START, 22) },
	metal_layers = nil,
	metal_spots = OVERLOOK_METAL,
	reclaimables = overlook_reclaimables,
	theme = OVERLOOK_THEME,
	campaign_only = true,
	points = { player_start = OVERLOOK_PLAYER_START, enemy_start = OVERLOOK_ENEMY_START },
	-- A warm afternoon, the sun lowering over the plateau's edge.
	atmosphere = {
		clock_time = 16.3,
		latitude = 25,
		sun_color = Color3.fromRGB(40, 26, 8),
		haze_color = Color3.fromRGB(190, 170, 140),
		decay_color = Color3.fromRGB(130, 112, 96),
		density = 0.3,
		haze = 1.6,
	},
} :: Preset)
