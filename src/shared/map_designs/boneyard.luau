--!strict
-- Boneyard: an old battlefield, grey and cratered, where a war was fought before this one and left its dead where they
-- fell. There is little metal in the ground, a few spots near each start and a few in the middle, and a great deal lying
-- on it: the wrecks of hundreds of units, thickest along the old front line across the middle, and the heaviest nearest
-- the centre. A side gets its metal by reclaiming them, and its army by raising them again.
--
-- The two sides start in opposite corners, and every wreck and crater has its twin across the middle, so each has as
-- much to take as the other. Nothing here depends on the seed but the roll of the ground.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)

type Preset = map_types.Preset
type Theme = map_types.Theme
type FixedWreck = map_types.FixedWreck

local SIZE = Vector2.new(768, 768)
local GROUND = 6
local ROLL = 2.5
local ROLL_FREQUENCY = 0.012
local FINE = 0.6
local FINE_FREQUENCY = 0.06
local NOISE = 31.1
-- The layout's own stream, so that it is the same whatever the seed.
local LAYOUT = 6661

-- The starts, in the south-west and north-east corners.
local WEST_START = Vector2.new(-270, -270)
-- The line from one start to the other, and the line across it that the old front ran along.
local AXIS = Vector2.new(1, 1).Unit
local FRONT = Vector2.new(1, -1).Unit

-- Old craters, shallow enough for anything to drive through: a bowl, and a low rim thrown up round it.
local CRATERS_EACH = 34
local CRATER_RADIUS = { 8, 26 }
local CRATER_DEPTH = 0.18
local CRATER_RIM = 0.04
-- how far out past the bowl the rim runs, as a share of the radius
local CRATER_RIM_RUN = 0.5

type Crater = { center: Vector2, radius: number }

-- One of the units the war was fought with: how wide its wreck lies, in studs from its middle, and how often it is
-- among the dead.
type Fallen = { def_name: string, radius: number, weight: number }

local LIGHT: { Fallen } = {
	{ def_name = "grunt", radius = 1.2, weight = 5 },
	{ def_name = "thug", radius = 1.4, weight = 3 },
	{ def_name = "aggravator", radius = 1.1, weight = 2 },
	{ def_name = "centurion", radius = 1.4, weight = 1 },
	{ def_name = "incisor", radius = 1.6, weight = 3 },
	{ def_name = "lasher", radius = 2.0, weight = 2 },
	{ def_name = "wolverine", radius = 1.8, weight = 2 },
	{ def_name = "brute", radius = 1.6, weight = 2 },
}
local MEDIUM: { Fallen } = {
	{ def_name = "sumo", radius = 1.6, weight = 2 },
	{ def_name = "sharpshooter", radius = 1.4, weight = 1 },
	{ def_name = "arbiter", radius = 1.6, weight = 1 },
	{ def_name = "gunslinger", radius = 1.7, weight = 1 },
	{ def_name = "tiger", radius = 1.8, weight = 2 },
	{ def_name = "quaker", radius = 1.9, weight = 1 },
	{ def_name = "negotiator", radius = 2.0, weight = 1 },
}
local HEAVY: { Fallen } = {
	{ def_name = "mammoth", radius = 2.8, weight = 1 },
	{ def_name = "fatboy", radius = 2.8, weight = 1 },
	{ def_name = "poison_arrow", radius = 2.5, weight = 1 },
	{ def_name = "shiva", radius = 2.8, weight = 1 },
	{ def_name = "vanguard", radius = 3.0, weight = 1 },
}

-- The battles: along the front, how far out from the middle each lies, give or take, how far across it its dead lie,
-- and how many of each weight. Each side's are on its own side of the front, and the other side has their twins.
type Battle = { along: number, toward: number, radius: number, light: number, medium: number, heavy: number }
local BATTLES: { Battle } = {
	{ along = 0, toward = -26, radius = 34, light = 8, medium = 5, heavy = 2 },
	{ along = 90, toward = -30, radius = 30, light = 9, medium = 3, heavy = 1 },
	{ along = -110, toward = -34, radius = 30, light = 9, medium = 3, heavy = 1 },
	{ along = 210, toward = -44, radius = 28, light = 10, medium = 2, heavy = 0 },
	{ along = -230, toward = -40, radius = 28, light = 10, medium = 2, heavy = 0 },
	{ along = 320, toward = -30, radius = 22, light = 7, medium = 1, heavy = 0 },
	{ along = -330, toward = -26, radius = 22, light = 7, medium = 1, heavy = 0 },
	-- skirmishes further back, toward the start
	{ along = 140, toward = -150, radius = 24, light = 6, medium = 0, heavy = 0 },
	{ along = -150, toward = -140, radius = 24, light = 6, medium = 0, heavy = 0 },
	{ along = 10, toward = -120, radius = 20, light = 5, medium = 1, heavy = 0 },
}

-- Wrecks keep this far from the starts, from the metal spots, and apart, edge to edge.
local START_CLEARANCE = 90
local SPOT_CLEARANCE = 8
local SPACING = 1.5
local ATTEMPTS_EACH = 16
local EDGE_MARGIN = 20

local ordinary: { Vector2 } = {
	-- home
	Vector2.new(-322, -250),
	Vector2.new(-250, -322),
	Vector2.new(-222, -222),
	Vector2.new(-336, -150),
	Vector2.new(-150, -336),
	-- the middle
	Vector2.new(-118, 36),
	Vector2.new(36, -118),
}
local SPOTS = kit.spots(kit.twinned(ordinary), nil)

local function lay_out_craters(): { Crater }
	local random = kit.stream(LAYOUT)
	local half = SIZE / 2
	local craters: { Crater } = {}
	-- whether a crater there would reach under a start or a spot, which have to be level
	local function in_the_way(center: Vector2, radius: number): boolean
		local reach = radius * (1 + CRATER_RIM_RUN) + 6
		if (center - WEST_START).Magnitude < reach + 40 or (center + WEST_START).Magnitude < reach + 40 then
			return true
		end
		for _, spot in SPOTS do
			if (center - spot.position).Magnitude < reach or (center + spot.position).Magnitude < reach then
				return true
			end
		end
		return false
	end
	local placed = 0
	while placed < CRATERS_EACH do
		local center = Vector2.new(random.range(-half.X, half.X), random.range(-half.Y, half.Y))
		local radius = random.range(CRATER_RADIUS[1], CRATER_RADIUS[2])
		if in_the_way(center, radius) then
			continue
		end
		table.insert(craters, { center = center, radius = radius })
		table.insert(craters, { center = -center, radius = radius })
		placed += 1
	end
	return craters
end

local CRATERS = lay_out_craters()

-- How much a crater sinks (x, z), or raises it on its rim.
local function crater_at(crater: Crater, x: number, z: number): number
	local distance = (Vector2.new(x, z) - crater.center).Magnitude / crater.radius
	if distance < 1 then
		return -CRATER_DEPTH * crater.radius * (1 - distance * distance)
	end
	local out = (distance - 1) / CRATER_RIM_RUN
	return CRATER_RIM * crater.radius * kit.smoothstep(out / 0.3) * kit.smoothstep((1 - out) / 0.7)
end

local function build(seed: number): (number, number) -> number
	return function(x: number, z: number): number
		local height = GROUND
			+ kit.twin_noise(x, z, ROLL_FREQUENCY, NOISE + seed) * ROLL
			+ kit.twin_noise(x, z, FINE_FREQUENCY, NOISE + 1.7 + seed) * FINE
		for _, crater in CRATERS do
			if
				math.abs(x - crater.center.X) < crater.radius * 1.6
				and math.abs(z - crater.center.Y) < crater.radius * 1.6
			then
				height += crater_at(crater, x, z)
			end
		end
		return height
	end
end

local function pick(from: { Fallen }, roll: number): Fallen
	local total = 0
	for _, fallen in from do
		total += fallen.weight
	end
	local left = roll * total
	for _, fallen in from do
		left -= fallen.weight
		if left < 0 then
			return fallen
		end
	end
	return from[#from]
end

type Lying = { at: Vector2, radius: number }

local function wrecks(): { FixedWreck }
	local random = kit.stream(LAYOUT + 1)
	local half = SIZE / 2
	local laid: { Lying } = {}
	local out: { FixedWreck } = {}

	local function clear(at: Vector2, radius: number): boolean
		if math.abs(at.X) > half.X - EDGE_MARGIN or math.abs(at.Y) > half.Y - EDGE_MARGIN then
			return false
		end
		if (at - WEST_START).Magnitude < START_CLEARANCE or (at + WEST_START).Magnitude < START_CLEARANCE then
			return false
		end
		for _, spot in SPOTS do
			if (at - spot.position).Magnitude < SPOT_CLEARANCE or (at + spot.position).Magnitude < SPOT_CLEARANCE then
				return false
			end
		end
		for _, other in laid do
			if (at - other.at).Magnitude < radius + other.radius + SPACING then
				return false
			end
		end
		return true
	end

	-- one of `from` somewhere in the battle round `middle`, and its twin across the middle of the map
	local function lay(from: { Fallen }, middle: Vector2, radius: number)
		local fallen = pick(from, random.next())
		for _ = 1, ATTEMPTS_EACH do
			local angle = random.range(0, math.pi * 2)
			local at = middle + Vector2.new(math.cos(angle), math.sin(angle)) * radius * math.sqrt(random.next())
			-- its twin has to fit as well, and must not be itself
			if at.Magnitude < fallen.radius + SPACING or clear(at, fallen.radius) == false then
				continue
			end
			local facing = random.range(0, math.pi * 2)
			table.insert(laid, { at = at, radius = fallen.radius })
			table.insert(laid, { at = -at, radius = fallen.radius })
			table.insert(out, { def_name = fallen.def_name, position = at, facing = facing })
			table.insert(out, { def_name = fallen.def_name, position = -at, facing = facing + math.pi })
			return
		end
	end

	for _, battle in BATTLES do
		local middle = FRONT * battle.along + AXIS * battle.toward
		for _ = 1, battle.heavy do
			lay(HEAVY, middle, battle.radius * 0.5)
		end
		for _ = 1, battle.medium do
			lay(MEDIUM, middle, battle.radius * 0.8)
		end
		for _ = 1, battle.light do
			lay(LIGHT, middle, battle.radius)
		end
	end
	return out
end

local THEME: Theme = {
	ground = Enum.Material.Ground,
	ground_patches = Enum.Material.Mud,
	slope = Enum.Material.Slate,
	cliff = Enum.Material.Basalt,
	shore = Enum.Material.Sand,
	seabed = Enum.Material.Sand,
	high_ground = nil,
	high_from = nil,
	colors = {
		[Enum.Material.Ground] = Color3.fromRGB(106, 98, 88),
		[Enum.Material.Mud] = Color3.fromRGB(84, 78, 70),
		[Enum.Material.Slate] = Color3.fromRGB(92, 90, 90),
		[Enum.Material.Basalt] = Color3.fromRGB(58, 56, 56),
		[Enum.Material.Sand] = Color3.fromRGB(150, 140, 120),
	},
	water_color = Color3.fromRGB(58, 70, 72),
	-- the craters are scorched
	paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
		return function(x: number, z: number, _height: number, _too_steep: boolean): Enum.Material?
			for _, crater in CRATERS do
				if (Vector2.new(x, z) - crater.center).Magnitude < crater.radius * 0.7 then
					return Enum.Material.Basalt
				end
			end
			return nil
		end
	end,
}

return table.freeze({
	name = "boneyard",
	display_name = "Boneyard",
	description = "An old battlefield, strewn with wrecks",
	source = "design",
	size = SIZE,
	build = build,
	starts = { WEST_START, -WEST_START },
	start_boxes = { kit.box_around(WEST_START, 60), kit.box_around(-WEST_START, 60) },
	metal_layers = nil,
	metal_spots = SPOTS,
	geo_spots = nil,
	reclaimables = nil,
	wrecks = wrecks,
	theme = THEME,
	conditions = nil,
	-- A dead grey day over an old battlefield, drained of colour, with ash sifting down.
	atmosphere = {
		clock_time = 14,
		brightness = 1.9,
		exposure = 0,
		ambient = Color3.fromRGB(122, 120, 116),
		outdoor_ambient = Color3.fromRGB(150, 148, 144),
		haze_color = Color3.fromRGB(150, 146, 142),
		decay_color = Color3.fromRGB(96, 92, 88),
		density = 0.34,
		haze = 2.2,
		glare = 0,
		saturation = -0.3,
		contrast = 0,
		weather = "ash",
		weather_amount = 1,
	},
} :: Preset)
