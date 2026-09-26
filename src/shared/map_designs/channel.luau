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

-- The player's shore is to the west and the enemy's to the east, and between them, from edge to edge of the map, a
-- channel of deep water with a long island in its middle, so that nothing that walks or drives gets across but a
-- commander, which wades along the floor. The player's shore runs down gently to the water all along, and a bay cut
-- into it, the harbour, is where a shipyard sits sheltered. The island's shores are gentle all round, somewhere to land
-- anywhere, and it has metal of its own. The enemy's shore stands above the water in low sea cliffs, too steep for
-- anything, but for two landing beaches: each runs up out of the water to a flat shelf, room for a lab put down by a
-- construction ship, and on up to the enemy's ground over a slope gentle enough for tanks. The channel is CHANNEL_FLOOR
-- deep, deep enough for submarines, and shelves up to every shore.
--
-- It is 640 by 512 studs. The strait between the player's shore and the island is some 110 studs across; the one
-- between the island and the enemy's shore some 90, so that the island's east shore is in an Agitator's reach (113
-- studs) of the enemy's cliff top, and the enemy's of it. None of it depends on the seed: the missions' forces stand
-- where they do against these shores.
local CHANNEL_SIZE = Vector2.new(640, 512)
-- The sea floor, and the tops of the shores and the island.
local CHANNEL_FLOOR = -12
local WEST_TOP = 6
local EAST_TOP = 8
local ISLAND_TOP = 7
-- The noise every part of it is drawn from, in place of the seed.
local CHANNEL_NOISE = 17.3
local CHANNEL_HILLS = 1.5
local CHANNEL_HILL_FREQUENCY = 0.02
-- The west shore's waterline wanders about WEST_X by as much as SHORE_WANDER either way; the east one's about EAST_X.
local WEST_X = -170
local EAST_X = 170
local SHORE_WANDER = 4
local SHORE_WANDER_FREQUENCY = 0.02
-- The island: an ellipse about ISLAND_CENTER, ISLAND_RADII across its waterline, whose outline wanders by as much as
-- ISLAND_WANDER of its size either way.
local ISLAND_CENTER = Vector2.new(10, 0)
local ISLAND_RADII = Vector2.new(70, 160)
local ISLAND_WANDER = 0.06
local ISLAND_WANDER_FREQUENCY = 0.025
-- The harbour: a bay cut BAY_DEPTH studs into the west shore about BAY_Z, BAY_HALF either side of it and no less, and
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
-- The shoals in the west strait, one under each of the metal spots on the channel's floor: a level top SHOAL_TOP deep
-- out to SHOAL_FLAT from its middle, shallow enough for an extractor (its footing's 20 elmos), falling away to the floor
-- by SHOAL_REACH.
local SHOALS = { Vector2.new(-135, -110), Vector2.new(-135, 150) }
local SHOAL_TOP = -1
local SHOAL_FLAT = 5
local SHOAL_REACH = 13
-- The landing beaches: about z = +-BEACH_Z, a beach for BEACH_HALF either side of that and no less, and BEACH_SIDE more
-- over which it turns back into cliff.
local BEACH_Z = 100
local BEACH_HALF = 14
local BEACH_SIDE = 6
-- The starts.
local PLAYER_START = Vector2.new(-260, 0)
local ENEMY_START = Vector2.new(265, 0)

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

-- The west shore, by how far inland of its waterline a place is (negative out on the water): the sea floor rising to a
-- gentle shore and up to the player's ground.
local WEST_PROFILE = {
	Vector2.new(-20, CHANNEL_FLOOR),
	Vector2.new(-6, -2),
	Vector2.new(0, 0.5),
	Vector2.new(10, 2),
	Vector2.new(22, WEST_TOP),
}
-- The island's shore, the same way: gentle all round.
local ISLAND_PROFILE = {
	Vector2.new(-20, CHANNEL_FLOOR),
	Vector2.new(-6, -2),
	Vector2.new(0, 0.5),
	Vector2.new(12, 2.5),
	Vector2.new(30, ISLAND_TOP),
}
-- The east shore where it is cliff: the sea floor rising to a ledge under the water, and a sheer face up to the top.
local CLIFF_PROFILE = {
	Vector2.new(-16, CHANNEL_FLOOR),
	Vector2.new(-4, -3),
	Vector2.new(0, EAST_TOP),
}
-- The east shore at a landing beach: up out of the water to a flat shelf a stud and a half above it, and on up to the
-- top over some 24 studs, about 15 degrees.
local BEACH_PROFILE = {
	Vector2.new(-22, CHANNEL_FLOOR),
	Vector2.new(-8, -1.5),
	Vector2.new(-2, 1.5),
	Vector2.new(14, 1.5),
	Vector2.new(38, EAST_TOP),
}

-- The x of the west shore's waterline at `z`, but for the harbour.
local function west_x(z: number): number
	return WEST_X + channel_noise(0.5, z, SHORE_WANDER_FREQUENCY, 1.1) * SHORE_WANDER * 2
end

-- The x of the east shore's cliff foot at `z`.
local function east_x(z: number): number
	return EAST_X + channel_noise(0.5, z, SHORE_WANDER_FREQUENCY, 2.2) * SHORE_WANDER * 2
end

-- How far inside the island's waterline (x, z) is, in studs across it (negative out on the water).
local function island_inland(x: number, z: number): number
	local offset = Vector2.new(x, z) - ISLAND_CENTER
	local across = Vector2.new(offset.X / ISLAND_RADII.X, offset.Y / ISLAND_RADII.Y).Magnitude
	local wander = channel_noise(x, z, ISLAND_WANDER_FREQUENCY, 4.4) * ISLAND_WANDER * 2
	return (1 + wander - across) * ISLAND_RADII.X
end

-- How much of a landing beach (x, z) is on, 1 on one and 0 on the cliffs.
local function beach(z: number): number
	return smoothstep((BEACH_HALF + BEACH_SIDE - math.abs(math.abs(z) - BEACH_Z)) / BEACH_SIDE)
end

-- How much of the harbour (x, z) is in, 1 over its level floor and 0 outside it.
local function harbor(x: number, z: number): number
	local across = smoothstep((BAY_HALF + BAY_SIDE - math.abs(z - BAY_Z)) / BAY_SIDE)
	local from_back = smoothstep((x - (WEST_X - BAY_DEPTH)) / BAY_BACK)
	local to_mouth = 1 - smoothstep((x - WEST_X) / BAY_MOUTH)
	return across * from_back * to_mouth
end

local function channel_build(_seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local west = profile(WEST_PROFILE, west_x(z) - x)
		local island = profile(ISLAND_PROFILE, island_inland(x, z))
		local inland = x - east_x(z)
		local b = beach(z)
		local east = profile(CLIFF_PROFILE, inland) * (1 - b) + profile(BEACH_PROFILE, inland) * b
		local ground = math.max(west, island, east)
		-- the land rolls a little, and the sea floor more gently; the shelves are left level for building on
		local hills = channel_noise(x, z, CHANNEL_HILL_FREQUENCY, 3.3) * CHANNEL_HILLS * 2
		local level = if ground > 1 then smoothstep((ground - 1.5) / 3) else 0.2
		ground += hills * level
		-- the harbour only ever deepens the ground, and a shoal only ever raises the floor
		local bay = harbor(x, z)
		ground = math.min(ground, ground + (BAY_FLOOR - ground) * bay)
		for _, shoal in SHOALS do
			local rise = kit.falloff((Vector2.new(x, z) - shoal).Magnitude, SHOAL_FLAT, SHOAL_REACH)
			ground = math.max(ground, ground + (SHOAL_TOP - ground) * rise)
		end
		return ground
	end
end

-- The meadow's grass and rock, with the beaches in sand.
local CHANNEL_THEME: Theme = table.clone(themes.TEMPERATE)
CHANNEL_THEME.water_color = Color3.fromRGB(40, 84, 104)
CHANNEL_THEME.paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
	return function(x: number, z: number, height: number, too_steep: boolean): Enum.Material?
		local on_beach = beach(z) > 0.5 and x > east_x(z) - 8 and x < east_x(z) + 20 and height < 3
		if on_beach and too_steep == false then
			return Enum.Material.Sand
		end
		return nil
	end
end

-- Six spots on the player's ground and two on the shoals off their shore, for construction ships; four on the island;
-- four on the enemy's ground, which it has extractors on from the start.
local CHANNEL_METAL: { FixedMetalSpot } = {}
for _, at in
	{
		Vector2.new(-270, -60),
		Vector2.new(-235, -115),
		Vector2.new(-285, 75),
		Vector2.new(-215, -25),
		Vector2.new(-255, 160),
		Vector2.new(-300, -150),
		SHOALS[1],
		SHOALS[2],
		Vector2.new(0, -100),
		Vector2.new(25, -35),
		Vector2.new(-5, 40),
		Vector2.new(20, 110),
		Vector2.new(230, -50),
		Vector2.new(230, 50),
		Vector2.new(290, -120),
		Vector2.new(290, 120),
	}
do
	table.insert(CHANNEL_METAL, { position = at, multiplier = nil })
end

-- Trees on the shores and the island, and rocks at the feet of the cliffs, holding what their defs say.
local function channel_reclaimables(): { FixedReclaimable }
	local laid: { { def_name: string, at: Vector2 } } = {
		{ def_name = "tree", at = Vector2.new(-300, -200) },
		{ def_name = "tree", at = Vector2.new(-290, -210) },
		{ def_name = "tree", at = Vector2.new(-305, 20) },
		{ def_name = "tree", at = Vector2.new(-300, 210) },
		{ def_name = "shrub", at = Vector2.new(-240, 30) },
		{ def_name = "shrub", at = Vector2.new(-230, -80) },
		{ def_name = "tree", at = Vector2.new(10, -130) },
		{ def_name = "tree", at = Vector2.new(0, 10) },
		{ def_name = "tree", at = Vector2.new(20, 70) },
		{ def_name = "shrub", at = Vector2.new(30, -70) },
		{ def_name = "tree", at = Vector2.new(305, -40) },
		{ def_name = "tree", at = Vector2.new(305, 40) },
		{ def_name = "shrub", at = Vector2.new(260, -200) },
		{ def_name = "shrub", at = Vector2.new(260, 200) },
		{ def_name = "rock", at = Vector2.new(200, -30) },
		{ def_name = "small_rock", at = Vector2.new(200, 30) },
	}
	local out: { FixedReclaimable } = {}
	for index, each in laid do
		table.insert(out, {
			def_name = each.def_name,
			position = each.at,
			facing = index * 1.7,
			metal = unit_defs.get(each.def_name).metal_cost,
			energy = unit_defs.get(each.def_name).energy_cost,
			buildpower = unit_defs.get(each.def_name).buildpower_cost,
		})
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
	-- a steady sea wind and a good tide, for the harbour's generators
	conditions = { min_wind = 4, max_wind = 14, tidal_strength = 20 },
	campaign_only = true,
	points = {
		player_start = PLAYER_START,
		enemy_start = ENEMY_START,
		-- the middle of the harbour's water, of the island, of the island's east shore within an Agitator's reach of the
		-- enemy's cliff top, and of each landing beach's shelf
		harbor = Vector2.new(WEST_X - BAY_DEPTH / 2 + 4, BAY_Z),
		island = ISLAND_CENTER,
		island_east = Vector2.new(ISLAND_CENTER.X + ISLAND_RADII.X - 12, 0),
		beach_north = Vector2.new(EAST_X + 6, -BEACH_Z),
		beach_south = Vector2.new(EAST_X + 6, BEACH_Z),
		-- a spot on the island's west shore, facing the player's harbour, gentle enough right by the water for a lab that a
		-- construction ship puts down from off the shore
		island_west = Vector2.new(-52, -30),
		-- where a fleet comes in from the sea or goes out to it: each strait's two ends
		sea_north = Vector2.new(-110, -245),
		sea_south = Vector2.new(-110, 245),
		east_north = Vector2.new(125, -245),
		east_south = Vector2.new(125, 245),
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
