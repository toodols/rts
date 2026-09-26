--!strict
-- Channel: the campaign's fifth and sixth missions (server/missions/channel.luau and blockade.luau), two shores with an
-- island between them, and no way across but by sea.

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

-- Two shores, west and east, and between them, from edge to edge of the map, a channel of deep water with a long island
-- in its middle, so that nothing that walks or drives gets across but a commander or a Garpike, which go along the
-- floor. It is symmetric about x = 0: the east half is the west half mirrored. Each shore runs down gently to the water
-- all along, and a bay cut into it, a harbour, is where a shipyard sits sheltered. The island's shores are gentle all
-- round, somewhere to land anywhere, and it has metal of its own. The channel is CHANNEL_FLOOR deep, deep enough for
-- submarines, and shelves up to every shore.
--
-- It is 640 by 512 studs. Each strait is some 100 studs across, so that an Agitator (113 studs) a little inland on
-- either side of one reaches most of the way across it. None of it depends on the seed: the missions' forces stand where
-- they do against these shores.
local CHANNEL_SIZE = Vector2.new(640, 512)
-- The sea floor, and the tops of the shores and the island.
local CHANNEL_FLOOR = -12
local SHORE_TOP = 6
local ISLAND_TOP = 7
-- The noise every part of it is drawn from, in place of the seed.
local CHANNEL_NOISE = 17.3
local CHANNEL_HILLS = 1.5
local CHANNEL_HILL_FREQUENCY = 0.02
-- Each shore's waterline wanders about SHORE_X from the middle by as much as SHORE_WANDER either way.
local SHORE_X = 170
local SHORE_WANDER = 4
local SHORE_WANDER_FREQUENCY = 0.02
-- The island: an ellipse about the middle, ISLAND_RADII across its waterline, whose outline wanders by as much as
-- ISLAND_WANDER of its size either way.
local ISLAND_RADII = Vector2.new(70, 160)
local ISLAND_WANDER = 0.06
local ISLAND_WANDER_FREQUENCY = 0.025
-- Each harbour: a bay cut BAY_DEPTH studs into its shore about BAY_Z, BAY_HALF either side of it and no less, and
-- BAY_SIDE more over which its sides rise back to the shore. Its floor is level, BAY_FLOOR deep, since nothing is built
-- afloat over a floor that falls away under it (placement_rules' MAX_BUILD_SLOPE_STUDS); its back shore runs down to it
-- over BAY_BACK studs, and its mouth opens out into the channel's slope over BAY_MOUTH more.
local BAY_Z = 70
local BAY_DEPTH = 30
local BAY_HALF = 14
local BAY_SIDE = 8
local BAY_FLOOR = -4
local BAY_BACK = 12
local BAY_MOUTH = 10
-- The shoals, one under each of the metal spots on the channel's floor, two in each strait: a level top SHOAL_TOP deep
-- out to SHOAL_FLAT from its middle, shallow enough for an extractor (its footing's 20 elmos), falling away to the floor
-- by SHOAL_REACH.
local SHOALS = { Vector2.new(-135, -110), Vector2.new(-135, 150), Vector2.new(135, -110), Vector2.new(135, 150) }
local SHOAL_TOP = -1
local SHOAL_FLAT = 5
local SHOAL_REACH = 13
-- The starts.
local PLAYER_START = Vector2.new(-260, 0)
local ENEMY_START = Vector2.new(260, 0)

local function channel_noise(x: number, z: number, frequency: number, offset: number): number
	return math.noise(x * frequency, z * frequency, CHANNEL_NOISE + offset)
end

-- The height along a profile of straight pieces: `points` are (distance, height) pairs in order of distance, and the
-- height is held level beyond either end.
local function profile(points: { Vector2 }, s: number): number
	if s <= points[1].X then
		return points[1].Y
	end
	for index = 2, #points do
		local a, b = points[index - 1], points[index]
		if s <= b.X then
			return a.Y + (b.Y - a.Y) * (s - a.X) / (b.X - a.X)
		end
	end
	return points[#points].Y
end

-- A shore, by how far inland of its waterline a place is (negative out on the water): the sea floor rising to a gentle
-- shore and up to the ground behind it.
local SHORE_PROFILE = {
	Vector2.new(-20, CHANNEL_FLOOR),
	Vector2.new(-6, -2),
	Vector2.new(0, 0.5),
	Vector2.new(10, 2),
	Vector2.new(22, SHORE_TOP),
}
-- The island's shore, the same way: gentle all round.
local ISLAND_PROFILE = {
	Vector2.new(-20, CHANNEL_FLOOR),
	Vector2.new(-6, -2),
	Vector2.new(0, 0.5),
	Vector2.new(12, 2.5),
	Vector2.new(30, ISLAND_TOP),
}

-- How far the shore's waterline at `z` is from the middle, but for the harbours: the same on both sides.
local function shore_x(z: number): number
	return SHORE_X + channel_noise(0.5, z, SHORE_WANDER_FREQUENCY, 1.1) * SHORE_WANDER * 2
end

-- How far inside the island's waterline (x, z) is, in studs across it (negative out on the water); `x` is measured
-- from the middle either way.
local function island_inland(x: number, z: number): number
	local across = Vector2.new(x / ISLAND_RADII.X, z / ISLAND_RADII.Y).Magnitude
	local wander = channel_noise(x, z, ISLAND_WANDER_FREQUENCY, 4.4) * ISLAND_WANDER * 2
	return (1 + wander - across) * ISLAND_RADII.X
end

-- How much of a harbour (x, z) is in, 1 over its level floor and 0 outside it; `x` is measured from the middle either
-- way.
local function harbor(x: number, z: number): number
	local across = smoothstep((BAY_HALF + BAY_SIDE - math.abs(z - BAY_Z)) / BAY_SIDE)
	local from_back = smoothstep(((SHORE_X + BAY_DEPTH) - x) / BAY_BACK)
	local to_mouth = 1 - smoothstep((SHORE_X - x) / BAY_MOUTH)
	return across * from_back * to_mouth
end

local function channel_build(_seed: number): (number, number) -> number
	return function(x: number, z: number): number
		-- everything is drawn from how far out from the middle (x, z) is, which is what makes the halves mirror each
		-- other
		local out = math.abs(x)
		local shore = profile(SHORE_PROFILE, out - shore_x(z))
		local island = profile(ISLAND_PROFILE, island_inland(out, z))
		local ground = math.max(shore, island)
		-- the land rolls a little, and the sea floor more gently; the shelves are left level for building on
		local hills = channel_noise(out, z, CHANNEL_HILL_FREQUENCY, 3.3) * CHANNEL_HILLS * 2
		local level = if ground > 1 then smoothstep((ground - 1.5) / 3) else 0.2
		ground += hills * level
		-- a harbour only ever deepens the ground, and a shoal only ever raises the floor
		local bay = harbor(out, z)
		ground = math.min(ground, ground + (BAY_FLOOR - ground) * bay)
		for _, shoal in SHOALS do
			local rise = kit.falloff((Vector2.new(x, z) - shoal).Magnitude, SHOAL_FLAT, SHOAL_REACH)
			ground = math.max(ground, ground + (SHOAL_TOP - ground) * rise)
		end
		return ground
	end
end

-- The meadow's grass and rock.
local CHANNEL_THEME: Theme = table.clone(themes.TEMPERATE)
CHANNEL_THEME.water_color = Color3.fromRGB(40, 84, 104)

-- On each side six spots on its shore and two on the shoals off it, for construction ships; four on the island, two on
-- each side of its middle. The enemy has extractors on its six ashore from the start.
local CHANNEL_METAL: { FixedMetalSpot } = {}
for _, at in
	{
		Vector2.new(-270, -60),
		Vector2.new(-235, -115),
		Vector2.new(-285, 75),
		Vector2.new(-215, -25),
		Vector2.new(-255, 160),
		Vector2.new(-300, -150),
		Vector2.new(-25, -95),
		Vector2.new(-25, 95),
	}
do
	table.insert(CHANNEL_METAL, { position = at, multiplier = nil })
	table.insert(CHANNEL_METAL, { position = Vector2.new(-at.X, at.Y), multiplier = nil })
end
for _, shoal in SHOALS do
	table.insert(CHANNEL_METAL, { position = shoal, multiplier = nil })
end

-- Trees and shrubs on the shores and the island, each on both sides, holding what their defs say.
local function channel_reclaimables(): { FixedReclaimable }
	local laid: { { def_name: string, at: Vector2 } } = {
		{ def_name = "tree", at = Vector2.new(-300, -200) },
		{ def_name = "tree", at = Vector2.new(-290, -210) },
		{ def_name = "tree", at = Vector2.new(-305, 20) },
		{ def_name = "tree", at = Vector2.new(-300, 210) },
		{ def_name = "shrub", at = Vector2.new(-240, 30) },
		{ def_name = "shrub", at = Vector2.new(-230, -80) },
		{ def_name = "tree", at = Vector2.new(-10, -130) },
		{ def_name = "tree", at = Vector2.new(-20, 10) },
		{ def_name = "shrub", at = Vector2.new(-30, -50) },
	}
	local out: { FixedReclaimable } = {}
	for index, each in laid do
		for _, side in { -1, 1 } do
			table.insert(out, {
				def_name = each.def_name,
				position = Vector2.new(each.at.X * -side, each.at.Y),
				facing = index * 1.7 * side,
				metal = unit_defs.get(each.def_name).metal_cost,
				energy = unit_defs.get(each.def_name).energy_cost,
				buildpower = unit_defs.get(each.def_name).buildpower_cost,
			})
		end
	end
	return out
end

return table.freeze({
	name = "channel",
	display_name = "Channel",
	source = "design",
	description = "Two shores with an island between them",
	build = channel_build,
	size = CHANNEL_SIZE,
	starts = { PLAYER_START, ENEMY_START },
	start_boxes = { box_around(PLAYER_START, 24), box_around(ENEMY_START, 24) },
	metal_layers = nil,
	metal_spots = CHANNEL_METAL,
	reclaimables = channel_reclaimables,
	theme = CHANNEL_THEME,
	-- a steady sea wind and a good tide, for the harbours' generators
	conditions = { min_wind = 4, max_wind = 14, tidal_strength = 20 },
	campaign_only = true,
	points = {
		player_start = PLAYER_START,
		enemy_start = ENEMY_START,
		-- the middle of the west harbour's water, of the island, and of the east shore's waterline
		harbor = Vector2.new(-(SHORE_X + BAY_DEPTH / 2 - 4), BAY_Z),
		island = Vector2.zero,
		east_shore = Vector2.new(SHORE_X, 0),
		-- a spot on each of the island's shores, gentle enough right by the water for a lab that a construction ship puts
		-- down from off the shore
		island_west = Vector2.new(-62, -30),
		island_east = Vector2.new(62, -30),
		-- where a fleet comes in from the sea or goes out to it: each strait's two ends
		sea_north = Vector2.new(-120, -245),
		sea_south = Vector2.new(-120, 245),
		east_north = Vector2.new(120, -245),
		east_south = Vector2.new(120, 245),
	},
	-- A grey morning on the water, the sun low in the east over the enemy's shore.
	atmosphere = {
		clock_time = 8.2,
		latitude = 35,
		sun_color = Color3.fromRGB(34, 30, 24),
		haze_color = Color3.fromRGB(170, 180, 186),
		decay_color = Color3.fromRGB(110, 118, 126),
		density = 0.32,
		haze = 1.8,
	},
} :: Preset)
