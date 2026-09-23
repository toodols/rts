-- Pictures of the maps, for picking one in a lobby, drawn here rather than uploaded.
--
-- Every map is a pure function of its preset and seed (see shared/map_presets.luau), so its picture is drawn from the
-- same heights and the same theme the game's terrain is built from: each pixel is painted the material the terrain
-- would be there (shared/ground_paint.luau), shaded by the slope under a light from the north west, and the sea laid
-- over what is under the waterline, deeper blue the deeper it is. The picture is as wide against as deep as the map
-- is, and is drawn once per map and kept.
--
-- Drawing yields every few rows, so a big map does not hitch the frame, and maps are drawn one at a time in the order
-- they are asked for.

local AssetService = game:GetService "AssetService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local React = require(ReplicatedStorage.Packages.react)

local config = require(ReplicatedStorage.Shared.config)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local bar_maps = require(ReplicatedStorage.Shared.bar_maps)
local ground_paint = require(ReplicatedStorage.Shared.ground_paint)

type Preset = map_presets.Preset

export type MapInfo = {
	preset: string,
	name: string,
	description: string,
	-- in studs, along x and z
	size: Vector2,
	-- in BAR's map units of 512 elmos, which is how BAR gives a map's size and what the grid over a picture is drawn in
	units: Vector2,
	-- how many starting places it has
	starts: number,
	-- brought over from Beyond All Reason, rather than made from the seed
	from_bar: boolean,
}

-- The longer side of every picture, in pixels.
local LONGEST = 256
-- how far either side of a pixel its slope is measured over
local SLOPE_STEP = config.CELL_STUDS / 2
-- The light, from the north west and well up: toward it, as (x, y, z).
local LIGHT = Vector3.new(-1, 1.6, -1).Unit
local AMBIENT = 0.5
-- How deep the sea has to be to be as dark as it gets, in studs, and how much of the ground shows through at the
-- shallowest and the deepest.
local FULL_DEPTH = 18
local SHALLOW_SHOW = 0.5
local DEEP_SHOW = 0.12
local ROWS_PER_YIELD = 24

local UNIT_STUDS = 512 / config.ELMOS_PER_STUD

local info_by_preset: { [string]: MapInfo } = {}
local images: { [string]: EditableImage } = {}
-- maps that could not be drawn, so they are not tried again
local failed: { [string]: boolean } = {}
local queue: { string } = {}
local queued: { [string]: boolean } = {}
local listeners: { [string]: { [() -> ()]: boolean } } = {}
local drawing = false

local bar_by_name: { [string]: bar_maps.BarMap } = {}
for _, map in bar_maps.MAPS do
	bar_by_name[map.name] = map
end

local function title_case(name: string): string
	local words = {}
	for _, word in string.split(name, "_") do
		table.insert(words, string.upper(string.sub(word, 1, 1)) .. string.sub(word, 2))
	end
	return table.concat(words, " ")
end

local function info(preset_name: string): MapInfo
	local existing = info_by_preset[preset_name]
	if existing ~= nil then
		return existing
	end
	local preset = map_presets.presets[preset_name]
	local size = if preset.size ~= nil
		then preset.size
		else Vector2.new(config.MAP_CELLS_X * config.CELL_STUDS, config.MAP_CELLS_Z * config.CELL_STUDS)
	local bar = bar_by_name[preset_name]
	local made: MapInfo = table.freeze({
		preset = preset_name,
		name = if bar ~= nil then bar.display_name else title_case(preset_name),
		description = preset.description,
		size = size,
		units = size / UNIT_STUDS,
		starts = if bar ~= nil then #bar.starts else config.START_SLOTS,
		from_bar = bar ~= nil,
	})
	info_by_preset[preset_name] = made
	return made
end

-- Every map, the ones made from a seed first and then BAR's from smallest to largest.
local function all(): { MapInfo }
	local result: { MapInfo } = {}
	for name in map_presets.presets do
		table.insert(result, info(name))
	end
	table.sort(result, function(a: MapInfo, b: MapInfo): boolean
		if a.from_bar ~= b.from_bar then
			return b.from_bar
		end
		local area_a = a.size.X * a.size.Y
		local area_b = b.size.X * b.size.Y
		if area_a ~= area_b then
			return area_a < area_b
		end
		return a.name < b.name
	end)
	return result
end

local function channel(value: number): number
	return math.clamp(math.round(value * 255), 0, 255)
end

local function draw(preset_name: string, seed: number): EditableImage?
	local preset = map_presets.presets[preset_name]
	local map = info(preset_name)
	local scale = LONGEST / math.max(map.size.X, map.size.Y)
	local width = math.max(1, math.round(map.size.X * scale))
	local depth = math.max(1, math.round(map.size.Y * scale))

	local height_at = preset.build(seed)
	local paint = ground_paint.make_painter(preset.theme, seed)
	local water = preset.theme.water_color
	local pixels = buffer.create(width * depth * 4)
	local studs_per_pixel_x = map.size.X / width
	local studs_per_pixel_z = map.size.Y / depth
	local west = -map.size.X / 2
	local north = -map.size.Y / 2

	for row = 0, depth - 1 do
		local z = north + (row + 0.5) * studs_per_pixel_z
		for column = 0, width - 1 do
			local x = west + (column + 0.5) * studs_per_pixel_x
			local height = height_at(x, z)
			local slope_x = (height_at(x + SLOPE_STEP, z) - height_at(x - SLOPE_STEP, z)) / (2 * SLOPE_STEP)
			local slope_z = (height_at(x, z + SLOPE_STEP) - height_at(x, z - SLOPE_STEP)) / (2 * SLOPE_STEP)
			local steepness = math.sqrt(slope_x * slope_x + slope_z * slope_z)

			local color = ground_paint.color_of(preset.theme, paint(x, z, height, steepness))
			local normal = Vector3.new(-slope_x, 1, -slope_z).Unit
			local light = AMBIENT + (1 - AMBIENT) * math.max(0, normal:Dot(LIGHT)) / LIGHT.Y
			local r, g, b = color.R * light, color.G * light, color.B * light

			local depth_below = config.WATER_LEVEL - height
			if depth_below > 0 then
				local shows = SHALLOW_SHOW + (DEEP_SHOW - SHALLOW_SHOW) * math.min(1, depth_below / FULL_DEPTH)
				r = r * shows + water.R * (1 - shows)
				g = g * shows + water.G * (1 - shows)
				b = b * shows + water.B * (1 - shows)
			end

			local at = (row * width + column) * 4
			buffer.writeu8(pixels, at, channel(r))
			buffer.writeu8(pixels, at + 1, channel(g))
			buffer.writeu8(pixels, at + 2, channel(b))
			buffer.writeu8(pixels, at + 3, 255)
		end
		if row % ROWS_PER_YIELD == ROWS_PER_YIELD - 1 then
			task.wait()
		end
	end

	-- nil when the device has no memory left to give to editable images
	local image = AssetService:CreateEditableImage({ Size = Vector2.new(width, depth) })
	if image == nil then
		return nil
	end
	image:WritePixelsBuffer(Vector2.zero, Vector2.new(width, depth), pixels)
	return image
end

local function notify(preset_name: string)
	local waiting = listeners[preset_name]
	if waiting == nil then
		return
	end
	for listener in waiting do
		task.spawn(listener)
	end
end

local function drain(seed: number)
	if drawing then
		return
	end
	drawing = true
	task.spawn(function()
		while #queue > 0 do
			local preset_name = table.remove(queue, 1) :: string
			local ok, result = pcall(draw, preset_name, seed)
			if ok and result ~= nil then
				images[preset_name] = result
			else
				warn(`the picture of {preset_name} could not be drawn: {result}`)
				failed[preset_name] = true
			end
			queued[preset_name] = nil
			notify(preset_name)
		end
		drawing = false
	end)
end

-- The picture of `preset_name`, if it has been drawn; otherwise asks for it to be.
local function image_of(preset_name: string, seed: number): EditableImage?
	local image = images[preset_name]
	if image ~= nil or failed[preset_name] == true or map_presets.presets[preset_name] == nil then
		return image
	end
	if queued[preset_name] == nil then
		queued[preset_name] = true
		table.insert(queue, preset_name)
		drain(seed)
	end
	return nil
end

-- A component's hook for the picture of `preset_name`: nil until it is drawn, and the picture once it is.
local function use_image(preset_name: string, seed: number): EditableImage?
	local _, redraw = React.useState(0)
	React.useEffect(function()
		local function listener()
			redraw(function(count: number): number
				return count + 1
			end)
		end
		local waiting = listeners[preset_name]
		if waiting == nil then
			waiting = {}
			listeners[preset_name] = waiting
		end
		waiting[listener] = true
		return function()
			waiting[listener] = nil
		end
	end, { preset_name })
	return image_of(preset_name, seed)
end

return table.freeze({
	UNIT_STUDS = UNIT_STUDS,
	info = info,
	all = all,
	image_of = image_of,
	use_image = use_image,
})
