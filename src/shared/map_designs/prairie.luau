--!strict
-- Prairie: a wide open grassland, made for vehicles. The ground rolls gently everywhere, and nowhere is it steeper than a
-- tank can drive, so the whole map is open to them and the view runs a long way. What little there is on it is only
-- there to break it up a little: a broad rise in the middle and a few lower ones about the map, a creek in each quarter
-- that winds in from the edge to a shallow pond, crossed every so often by a dry, muddy ford, and a few groves of trees
-- and fields of rocks, laid out from the seed as on any map.
--
-- The metal is spread thinly over all of the open ground, so that a player who stays home falls behind one who
-- spreads out, and every spot out in the open is something to raid. The rich spots are on the rise in the middle.
--
-- Every quarter of the map is the same as the others turned about the middle. It seats eight: one start in each corner
-- and one halfway along each edge. The corners come first, the first two across the map from each other, as far apart
-- as the map allows, so that two players, or two teams, start in opposite corners and four in one each; the starts on
-- the edges are for the rest.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

type Preset = map_types.Preset
type Theme = map_types.Theme
type StartBox = map_types.StartBox

local SIZE = Vector2.new(1024, 1024)
local LAND = 5
-- The long, low swells the whole map rolls in, and the finer ripple over them. Both are gentle enough that together
-- they come nowhere near the steepest a tank drives (27 degrees).
local ROLL = 3.5
local ROLL_FREQUENCY = 0.005
local RIPPLE = 0.8
local RIPPLE_FREQUENCY = 0.02
local NOISE = 211.7
-- Around every start the ground rolls less, so that there is room to build: the roll is calmed by START_CALM within
-- CALM_INNER studs of a start, easing back to the full roll by CALM_OUTER.
local START_CALM = 0.8
local CALM_INNER = 60
local CALM_OUTER = 120

-- The corner and edge starts of the first quarter; the others are them turned.
local CORNER_START = Vector2.new(-370, -370)
local EDGE_START = Vector2.new(0, -400)

local function turned(at: Vector2, quarters: number): Vector2
	local out = at
	for _ = 1, quarters do
		out = Vector2.new(-out.Y, out.X)
	end
	return out
end

-- The corners first, across from each other in pairs, so that two players are in opposite corners and four in one
-- each; then the edges in the same order.
local STARTS: { Vector2 } = {}
for _, start in { CORNER_START, EDGE_START } do
	for _, quarters in { 0, 2, 1, 3 } do
		table.insert(STARTS, turned(start, quarters))
	end
end
local BOXES: { StartBox } = {}
for index, start in STARTS do
	table.insert(BOXES, kit.box_around(start, if index <= 4 then 56 else 44))
end

-- A rise: flat on top out to a third of its radius, and falling gently from there to the ground at its radius. None
-- falls faster than 1.5 times its height over two thirds of its radius, far gentler than a tank's limit.
type Rise = { center: Vector2, radius: number, height: number }

local RISES: { Rise } = { { center = Vector2.zero, radius = 110, height = 6 } }
for _, rise in
	{
		-- ahead of the corner start, between it and the edge start
		{ center = Vector2.new(-170, -270), radius = 70, height = 6 },
		-- between the edge start and the middle
		{ center = Vector2.new(-60, -210), radius = 46, height = 4 },
		-- beside the corner start, along the edge
		{ center = Vector2.new(-290, -470), radius = 50, height = 4 },
	} :: { Rise }
do
	for quarters = 0, 3 do
		table.insert(RISES, { center = turned(rise.center, quarters), radius = rise.radius, height = rise.height })
	end
end

-- The ponds, one to a quarter, each at the end of that quarter's creek: shallow, with a long, gentle shore.
local POND_CENTER = Vector2.new(-190, -95)
local POND_RADIUS = 30
local POND_SHORE = 50
local POND_BED = -2.5
local PONDS = kit.quartered({ POND_CENTER })

-- The creeks, winding in from the edge to the ponds, their banks falling to the bed over CREEK_BANK studs either side.
-- The bed is under water, but for a ford every FORD_EVERY studs along it, starting FIRST_FORD in from the edge, where it
-- rises out of the water for FORD_RADIUS studs round and eases back down over FORD_EASE more: a strip of mud that a
-- vehicle drives across. The fords are points rather than stretches measured along the creek, so that they are the
-- same shape on the inside of a bend as on the outside.
local CREEK_POINTS = {
	Vector2.new(-500, -185),
	Vector2.new(-420, -165),
	Vector2.new(-335, -195),
	Vector2.new(-255, -150),
	POND_CENTER,
}
local CREEK_HALF_WIDTH = 6
local CREEK_BANK = 40
local CREEK_DEEP = -1.5
local CREEK_FORD = 1.5
local FIRST_FORD = 60
local FORD_EVERY = 100
local FORD_RADIUS = 14
local FORD_EASE = 24

type Creek = { points: { Vector2 }, low: Vector2, high: Vector2 }

local CREEKS: { Creek } = {}
local FORDS: { Vector2 } = {}
for quarters = 0, 3 do
	local points: { Vector2 } = {}
	local reach = CREEK_HALF_WIDTH + CREEK_BANK
	local low, high = Vector2.new(math.huge, math.huge), Vector2.new(-math.huge, -math.huge)
	for _, point in CREEK_POINTS do
		local at = turned(point, quarters)
		table.insert(points, at)
		low = Vector2.new(math.min(low.X, at.X - reach), math.min(low.Y, at.Y - reach))
		high = Vector2.new(math.max(high.X, at.X + reach), math.max(high.Y, at.Y + reach))
	end
	table.insert(CREEKS, { points = points, low = low, high = high })

	local before, next_ford = 0, FIRST_FORD
	for index = 1, #points - 1 do
		local a, b = points[index], points[index + 1]
		local length = (b - a).Magnitude
		while next_ford <= before + length do
			table.insert(FORDS, a:Lerp(b, (next_ford - before) / length))
			next_ford += FORD_EVERY
		end
		before += length
	end
end

-- How far (x, z) is from the middle of `creek`.
local function to_creek(creek: Creek, x: number, z: number): number
	local nearest = math.huge
	for index = 1, #creek.points - 1 do
		local distance = kit.to_segment(x, z, creek.points[index], creek.points[index + 1])
		nearest = math.min(nearest, distance)
	end
	return nearest
end

-- How far the bed at (x, z) is raised toward a ford: 1 on one, 0 away from them all.
local function ford_at(at: Vector2): number
	local ford = 0
	for _, center in FORDS do
		ford = math.max(ford, kit.falloff((at - center).Magnitude, FORD_RADIUS, FORD_RADIUS + FORD_EASE))
	end
	return ford
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local at = Vector2.new(x, z)
		local calm = 0
		for _, start in STARTS do
			calm = math.max(calm, kit.falloff((at - start).Magnitude, CALM_INNER, CALM_OUTER))
		end
		local roll = kit.quarter_noise(x, z, ROLL_FREQUENCY, NOISE + seed) * ROLL
			+ kit.quarter_noise(x, z, RIPPLE_FREQUENCY, NOISE + 3.1 + seed) * RIPPLE
		local height = LAND + roll * (1 - calm * START_CALM)
		for _, rise in RISES do
			height += rise.height * kit.falloff((at - rise.center).Magnitude, rise.radius / 3, rise.radius)
		end
		for _, creek in CREEKS do
			if kit.within(x, z, creek.low, creek.high) then
				local weight = kit.smoothstep((CREEK_HALF_WIDTH + CREEK_BANK - to_creek(creek, x, z)) / CREEK_BANK)
				if weight > 0 then
					local bed = kit.lerp(CREEK_DEEP, CREEK_FORD, ford_at(at))
					height = kit.lerp(height, math.min(height, bed), weight)
				end
			end
		end
		for _, pond in PONDS do
			local weight = kit.falloff((at - pond).Magnitude, POND_RADIUS, POND_RADIUS + POND_SHORE)
			height = kit.lerp(height, math.min(height, POND_BED), weight)
		end
		return height
	end
end

local SPOTS = kit.spots(
	kit.quartered({
		-- by the corner start
		CORNER_START + Vector2.new(-32, 22),
		CORNER_START + Vector2.new(22, -32),
		CORNER_START + Vector2.new(30, 30),
		CORNER_START + Vector2.new(-30, -30),
		-- by the edge start
		EDGE_START + Vector2.new(-34, -18),
		EDGE_START + Vector2.new(34, -18),
		EDGE_START + Vector2.new(0, 36),
		-- out on the open ground
		Vector2.new(-250, -430),
		Vector2.new(-470, -270),
		Vector2.new(-235, -345),
		Vector2.new(-285, -255),
		Vector2.new(-190, -195),
		Vector2.new(-105, -310),
		Vector2.new(-115, -150),
		Vector2.new(-60, -210),
		Vector2.new(-470, -465),
		Vector2.new(-340, -110),
		Vector2.new(-95, -55),
	}),
	-- on the rise in the middle
	kit.quartered({ Vector2.new(40, 14) })
)

-- A vent to a quarter, out between the corner start and the edge start.
local VENTS = kit.quartered({ Vector2.new(-185, -385) })

local THEME: Theme = {
	ground = Enum.Material.Grass,
	ground_patches = Enum.Material.LeafyGrass,
	slope = Enum.Material.Ground,
	cliff = Enum.Material.Rock,
	shore = Enum.Material.Mud,
	seabed = Enum.Material.Mud,
	high_ground = nil,
	high_from = nil,
	colors = {
		[Enum.Material.Grass] = Color3.fromRGB(122, 148, 70),
		[Enum.Material.LeafyGrass] = Color3.fromRGB(152, 150, 82),
		[Enum.Material.Ground] = Color3.fromRGB(130, 110, 78),
		[Enum.Material.Mud] = Color3.fromRGB(98, 86, 64),
		[Enum.Material.Rock] = Color3.fromRGB(120, 116, 108),
	},
	water_color = Color3.fromRGB(52, 100, 112),
	paint = nil,
}

return table.freeze({
	name = "prairie",
	display_name = "Prairie",
	description = "Open grassland for vehicles, for two to eight",
	source = "design",
	size = SIZE,
	build = build,
	starts = STARTS,
	start_boxes = BOXES,
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = function(): { Vector2 }
		return VENTS
	end,
	reclaimables = nil,
	wrecks = nil,
	theme = THEME,
	-- a light breeze: enough to turn a wind turbine, never a gale
	conditions = { min_wind = 3, max_wind = 10 },
	-- A clear afternoon over the grass: a high, bright sun, a blue sky, and the haze kept thin so the view runs far.
	atmosphere = {
		clock_time = 15.2,
		latitude = 40,
		brightness = 2.6,
		haze_color = Color3.fromRGB(170, 196, 222),
		decay_color = Color3.fromRGB(120, 150, 182),
		density = 0.22,
		haze = 0.8,
		glare = 0.2,
		saturation = 0.08,
	},
} :: Preset)
