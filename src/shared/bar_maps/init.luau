-- Beyond All Reason's maps, brought over from the images on their pages by tools/bar_maps/import_bar_maps.py, which
-- writes one data module here for each. A map is exactly as big as it is in BAR, at config.ELMOS_PER_STUD, and its data
-- has one height sample to each corner of the game's heightmap cells and one material to each cell, so it is laid
-- down as it is: centred on (0, 0), and never stretched or shrunk.
--
-- What lies on each map, its geothermal vents and its reclaimable features, is in a module of its own beside it, written
-- by tools/bar_maps/import_bar_features.py from the map's archive (`features_of`).
--
-- In the data, a position is a fraction of the map across (u, from its west edge) and down (v, from its north edge);
-- here u runs along +x and v along +z, which is the same way round as the map's picture seen from above with north at
-- the top.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local config = require(ReplicatedStorage.Shared.config)
local rights = require(script.rights)

local supreme_isthmus = require(script.supreme_isthmus)
local hooked = require(script.hooked)
local center_command = require(script.center_command)
local rifted = require(script.rifted)
local comet_catcher = require(script.comet_catcher)
local altair_crossing = require(script.altair_crossing)
local ancient_bastion = require(script.ancient_bastion)
local folsom_dam = require(script.folsom_dam)

-- What lies on a map, as its `<name>_features` module has it (see tools/bar_maps/import_bar_features.py).
export type Features = {
	geovents: { Vector2 },
	-- one reclaimable a line: what it is drawn as, across, down, heading, metal, energy, reclaim buildpower
	features: string,
}

-- One reclaimable, read out of a `Features`: where it is as a fraction of the map, and what it holds.
export type Feature = {
	def_name: string,
	at: Vector2,
	heading: number,
	metal: number,
	energy: number,
	buildpower: number,
}

export type MetalSpot = {
	at: Vector2,
	rich: boolean,
}

export type BarMap = {
	name: string,
	display_name: string,
	size: Vector2,
	cells_x: number,
	cells_z: number,
	lowest: number,
	highest: number,
	heights: string,
	cells: string,
	materials: { Enum.Material },
	colors: { [Enum.Material]: Color3 },
	cliff: Enum.Material,
	water_color: Color3,
	-- the least and most the wind blows there, and how strong the tide is, from the map's page
	min_wind: number,
	max_wind: number,
	tidal_strength: number,
	starts: { Vector2 },
	-- each team's start box, its corners as fractions of the map across and down, as `starts` are
	start_boxes: { { min: Vector2, max: Vector2 } },
	metal: { MetalSpot },
}

-- A BAR map laid down in the world, in studs.
export type Fitted = {
	map: BarMap,
	-- how big it is, along x and z
	size: Vector2,
	height_at: (x: number, z: number) -> number,
	-- what the map's texture has at (x, z); nil beyond its edges
	material_at: (x: number, z: number) -> Enum.Material?,
	-- a fraction of the map across and down to where that is in the world, as (x, z)
	to_world: (at: Vector2) -> Vector2,
}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local DECODE: { [number]: number } = {}
for index = 1, #ALPHABET do
	DECODE[string.byte(ALPHABET, index)] = index - 1
end

-- Base64 to bytes. Anything that is not in the alphabet, like the line breaks and the padding, is passed over.
local function decode(text: string): buffer
	local out = buffer.create(#text * 3 // 4)
	local length = 0
	local bits = 0
	local held = 0
	for index = 1, #text do
		local value = DECODE[string.byte(text, index)]
		if value == nil then
			continue
		end
		held = bit32.bor(bit32.lshift(held, 6), value)
		bits += 6
		if bits >= 8 then
			bits -= 8
			buffer.writeu8(out, length, bit32.band(bit32.rshift(held, bits), 0xFF))
			length += 1
			held = bit32.band(held, bit32.lshift(1, bits) - 1)
		end
	end
	local trimmed = buffer.create(length)
	buffer.copy(trimmed, 0, out, 0, length)
	return trimmed
end

local function fit(map: BarMap): Fitted
	local heights = decode(map.heights)
	local cells = decode(map.cells)
	local samples_x = map.cells_x + 1
	assert(buffer.len(heights) == samples_x * (map.cells_z + 1), `{map.name}: the heights are the wrong length`)
	assert(buffer.len(cells) == map.cells_x * map.cells_z, `{map.name}: the cells are the wrong length`)

	local width = map.cells_x * config.CELL_STUDS
	local depth = map.cells_z * config.CELL_STUDS
	local west = -width / 2
	local north = -depth / 2
	local height_per_byte = (map.highest - map.lowest) / 255 / config.ELMOS_PER_STUD
	local height_base = map.lowest / config.ELMOS_PER_STUD

	local function sample(ix: number, iz: number): number
		local byte = buffer.readu8(heights, iz * samples_x + ix)
		return height_base + byte * height_per_byte
	end

	local function height_at(x: number, z: number): number
		local gx = (x - west) / width * map.cells_x
		local gz = (z - north) / depth * map.cells_z
		local clamped_x = math.clamp(gx, 0, map.cells_x)
		local clamped_z = math.clamp(gz, 0, map.cells_z)
		local x0 = math.min(math.floor(clamped_x), map.cells_x - 1)
		local z0 = math.min(math.floor(clamped_z), map.cells_z - 1)
		local tx = clamped_x - x0
		local tz = clamped_z - z0
		local top = sample(x0, z0) + (sample(x0 + 1, z0) - sample(x0, z0)) * tx
		local bottom = sample(x0, z0 + 1) + (sample(x0 + 1, z0 + 1) - sample(x0, z0 + 1)) * tx
		return top + (bottom - top) * tz
	end

	local function material_at(x: number, z: number): Enum.Material?
		local cx = math.floor((x - west) / width * map.cells_x)
		local cz = math.floor((z - north) / depth * map.cells_z)
		if cx < 0 or cx >= map.cells_x or cz < 0 or cz >= map.cells_z then
			return nil
		end
		return map.materials[buffer.readu8(cells, cz * map.cells_x + cx) + 1]
	end

	local function to_world(at: Vector2): Vector2
		return Vector2.new(west + at.X * width, north + at.Y * depth)
	end

	return table.freeze({
		map = map,
		size = Vector2.new(width, depth),
		height_at = height_at,
		material_at = material_at,
		to_world = to_world,
	})
end

local ALL_MAPS: { BarMap } = {
	supreme_isthmus,
	hooked,
	center_command,
	rifted,
	comet_catcher,
	altair_crossing,
	ancient_bastion,
	folsom_dam,
}

-- The maps in the game: in Studio every one, and anywhere else only those whose makers have said we may use them
-- (see rights.luau). The rest are a developer's maps, as if they were not part of the game: no preset is made for
-- them, so a lobby does not offer them and nothing can load them.
local MAPS: { BarMap } = {}
for _, map in ALL_MAPS do
	if RunService:IsStudio() or rights.of(map.name).status == "permitted" then
		table.insert(MAPS, map)
	end
end

-- The geothermal vents and reclaimables of the map called `name`, from its features module.
local function features_of(name: string): Features
	return require(script:FindFirstChild(`{name}_features`) :: ModuleScript) :: Features
end

-- Every reclaimable in `features`, read out of its lines.
local function read_features(features: Features): { Feature }
	local out: { Feature } = {}
	for line in string.gmatch(features.features, "[^\n]+") do
		local def_name, u, v, heading, metal, energy, buildpower =
			string.match(line, "^(%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)")
		if def_name == nil then
			continue
		end
		table.insert(out, {
			def_name = def_name,
			at = Vector2.new(tonumber(u) :: number, tonumber(v) :: number),
			heading = tonumber(heading) :: number,
			metal = tonumber(metal) :: number,
			energy = tonumber(energy) :: number,
			buildpower = tonumber(buildpower) :: number,
		})
	end
	return out
end

return table.freeze({
	MAPS = MAPS,
	rights = rights,
	fit = fit,
	features_of = features_of,
	read_features = read_features,
})
