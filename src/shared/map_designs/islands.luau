--!strict
-- Islands: islands in an ocean, one under every start, more scattered between, and at least one volcano, a cone far
-- steeper than anything can be built on; all generated from the seed.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_types = require(ReplicatedStorage.Shared.map_types)
local kit = require(script.Parent.kit)
local themes = require(script.Parent.themes)

type Preset = map_types.Preset
type Theme = map_types.Theme

local SIZE = kit.GENERATED_SIZE
local HALF_X = SIZE.X / 2
local HALF_Z = SIZE.Y / 2
local SEA_FLOOR = kit.SEA_FLOOR
-- How high an ordinary island stands, at its plateau, and how far across it the plateau reaches.
local START_ISLAND_RADIUS = 95
local START_ISLAND_TOP = 7
local PLATEAU_FRACTION = 0.5
local OTHER_ISLAND_COUNT = 6
local OTHER_RADIUS_MIN = 45
local OTHER_RADIUS_MAX = 80
local OTHER_TOP_MIN = 5
local OTHER_TOP_MAX = 9
-- Water kept between any two islands, and between an island and the map edge.
local ISLAND_GAP = 24
local EDGE_MARGIN = 16
-- The volcano: how wide it is at the base, how tall, how sharply it climbs (above 1 it is steeper towards
-- the top), and the crater at its summit. It is on the middle of the map, and now and then another
-- island is one too.
local VOLCANO_RADIUS = 65
local VOLCANO_PEAK = 85
local VOLCANO_SHARPNESS = 1.1
local CRATER_FRACTION = 0.12
local CRATER_DEPTH = 14
local EXTRA_VOLCANO_CHANCE = 0.25
local MAX_ATTEMPTS = 400
-- How ragged the coasts are: the shore distance is scaled by up to this much either way.
local COAST_WARP = 0.22
-- Decorrelates the layout from the noise, which is seeded with the same number.
local SEED_OFFSET = 4242

type Island = {
	x: number,
	z: number,
	radius: number,
	top: number,
	volcano: boolean,
}

local STARTS = kit.ring_starts(kit.RING_RADIUS)

local function room_for(islands: { Island }, x: number, z: number, radius: number): boolean
	if math.abs(x) > HALF_X - EDGE_MARGIN - radius or math.abs(z) > HALF_Z - EDGE_MARGIN - radius then
		return false
	end
	for _, other in islands do
		local distance = math.sqrt((other.x - x) ^ 2 + (other.z - z) ^ 2)
		if distance < other.radius + radius + ISLAND_GAP then
			return false
		end
	end
	return true
end

local function lay_out_islands(seed: number): { Island }
	local random = Random.new(seed + SEED_OFFSET)
	local islands: { Island } = {}

	-- the volcano first, at the middle, so nothing else takes its place
	table.insert(islands, {
		x = random:NextNumber(-40, 40),
		z = random:NextNumber(-40, 40),
		radius = VOLCANO_RADIUS,
		top = VOLCANO_PEAK,
		volcano = true,
	})

	-- every team has an island of its own, with a flat top to start on, centred on where the ring puts the start
	for slot = 1, #STARTS do
		local angle = kit.ring_angle(slot)
		table.insert(islands, {
			x = math.cos(angle) * kit.RING_RADIUS,
			z = math.sin(angle) * kit.RING_RADIUS,
			radius = START_ISLAND_RADIUS,
			top = START_ISLAND_TOP,
			volcano = false,
		})
	end

	local placed = 0
	for _ = 1, MAX_ATTEMPTS do
		if placed >= OTHER_ISLAND_COUNT then
			break
		end
		local volcano = random:NextNumber() < EXTRA_VOLCANO_CHANCE
		local radius = if volcano then VOLCANO_RADIUS else random:NextNumber(OTHER_RADIUS_MIN, OTHER_RADIUS_MAX)
		local x = random:NextNumber(-HALF_X, HALF_X)
		local z = random:NextNumber(-HALF_Z, HALF_Z)
		if room_for(islands, x, z, radius) then
			table.insert(islands, {
				x = x,
				z = z,
				radius = radius,
				top = if volcano
					then random:NextNumber(VOLCANO_PEAK * 0.8, VOLCANO_PEAK)
					else random:NextNumber(OTHER_TOP_MIN, OTHER_TOP_MAX),
				volcano = volcano,
			})
			placed += 1
		end
	end
	if placed < OTHER_ISLAND_COUNT then
		warn(`only found room for {placed} of {OTHER_ISLAND_COUNT} extra islands`)
	end
	return islands
end

-- The height an island gives a point `distance` from its centre.
local function island_height(island: Island, distance: number): number
	local radius = island.radius
	if island.volcano then
		local rim = radius * CRATER_FRACTION
		local function cone(from_centre: number): number
			local t = math.clamp(1 - from_centre / radius, 0, 1)
			return SEA_FLOOR + (island.top - SEA_FLOOR) * t ^ VOLCANO_SHARPNESS
		end
		if distance < rim then
			-- the crater: a bowl sunk into the summit
			local inside = distance / rim
			return cone(rim) - CRATER_DEPTH * (1 - inside * inside)
		end
		return cone(distance)
	end
	-- a flat top that falls away to the sea bed in an S, so the shore slopes gently
	local rise = kit.smoothstep((radius - distance) / (radius * (1 - PLATEAU_FRACTION)))
	return SEA_FLOOR + (island.top - SEA_FLOOR) * rise
end

-- The islands are tropical, and every volcano's crater is still hot.
local function paint(seed: number): (number, number, number, boolean) -> Enum.Material?
	local volcanoes = {}
	for _, island in lay_out_islands(seed) do
		if island.volcano then
			table.insert(volcanoes, island)
		end
	end
	return function(x: number, z: number, height: number, _too_steep: boolean): Enum.Material?
		for _, volcano in volcanoes do
			local distance = math.sqrt((x - volcano.x) ^ 2 + (z - volcano.z) ^ 2)
			if distance < volcano.radius * CRATER_FRACTION then
				return Enum.Material.CrackedLava
			end
			if distance < volcano.radius * 0.6 and height > START_ISLAND_TOP + 4 then
				return Enum.Material.Basalt
			end
		end
		return nil
	end
end

local function build(seed: number): (number, number) -> number
	local islands = lay_out_islands(seed)
	return function(x: number, z: number): number
		local height = SEA_FLOOR
		for index, island in islands do
			local dx = x - island.x
			local dz = z - island.z
			local distance = math.sqrt(dx * dx + dz * dz)
			-- ragged coasts: the same island seen a little nearer or further away from place to place
			local warp = math.noise(x * kit.COAST_FREQUENCY, z * kit.COAST_FREQUENCY, seed + index * 7.31) * COAST_WARP
			height = math.max(height, island_height(island, distance * (1 + warp)))
		end
		return height + kit.ripple(x, z, seed)
	end
end

local THEME: Theme = table.clone(themes.TROPICAL)
THEME.paint = paint

return table.freeze({
	name = "islands",
	display_name = "Islands",
	description = "Islands and a volcano",
	source = "generated",
	size = SIZE,
	build = build,
	starts = STARTS,
	-- the flat top of each start island, which is START_ISLAND_RADIUS across, so a square inside it
	start_boxes = kit.ring_boxes(kit.RING_RADIUS, 60),
	metal_layers = nil,
	metal_spots = nil,
	theme = THEME,
	-- A tropical afternoon: a high hot sun, a humid sea haze and colours a little brighter than life.
	atmosphere = {
		clock_time = 13.5,
		latitude = 10,
		brightness = 2.6,
		exposure = 0,
		outdoor_ambient = Color3.fromRGB(112, 124, 128),
		haze_color = Color3.fromRGB(160, 196, 204),
		decay_color = Color3.fromRGB(110, 150, 160),
		density = 0.3,
		haze = 1.6,
		glare = 0.3,
		tint = Color3.fromRGB(255, 250, 240),
		saturation = 0.15,
	},
} :: Preset)
