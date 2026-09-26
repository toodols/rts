--!strict
-- Pictures of the maps, for picking one in a lobby, drawn here rather than uploaded.
--
-- Every map is a pure function of its preset and seed (see shared/map_presets), so its picture is drawn from the same
-- heights and the same theme the game's terrain is built from: each pixel is painted the material the terrain would be
-- there (shared/ground_paint.luau), shaded by the slope under a light from the north west, and the sea laid over what is
-- under the waterline, deeper blue the deeper it is. The picture is as wide against as deep as the map is, and is drawn
-- once for each map and seed and kept.
--
-- Drawing yields every few rows, so a big map does not hitch the frame, and pictures are drawn one at a time in the
-- order they are asked for.

local AssetService = game:GetService "AssetService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local ground_paint = require(ReplicatedStorage.Shared.ground_paint)
local signal = require(ReplicatedStorage.Shared.signal)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

type Preset = map_presets.Preset

-- One picture to draw: a map from a seed.
type Wanted = {
	preset: string,
	seed: number,
}

-- The longer side of every picture, in pixels.
local LONGEST = 256
-- how far either side of a pixel its slope is measured over
local SLOPE_STEP = world_scale.CELL_STUDS / 2
-- The light, from the north west and well up: toward it, as (x, y, z).
local LIGHT = Vector3.new(-1, 1.6, -1).Unit
local AMBIENT = 0.5
-- How deep the sea has to be to be as dark as it gets, in studs, and how much of the ground shows through at the
-- shallowest and the deepest.
local FULL_DEPTH = 18
local SHALLOW_SHOW = 0.5
local DEEP_SHOW = 0.12
local ROWS_PER_YIELD = 24

-- Every picture drawn and every one that could not be, by `key_of` its map and seed, so neither is tried again.
local images: { [string]: EditableImage } = {}
local failed: { [string]: boolean } = {}
local queue: { Wanted } = {}
local queued: { [string]: boolean } = {}
local drawing = false
-- Fires with a picture's key once it is drawn, or could not be.
local drawn = signal.new() :: signal.Signal<string>

local function key_of(preset_name: string, seed: number): string
	return `{preset_name}|{seed}`
end

-- How big `preset` is in BAR's map units of 512 elmos, which is how BAR gives a map's size and what the grid over a
-- picture is drawn in.
local function units_of(preset: Preset): Vector2
	return preset.size / world_scale.MAP_UNIT_STUDS
end

-- `preset`'s size in map units, as the lobby shows it.
local function units_text(preset: Preset): string
	local units = units_of(preset)
	return `{math.round(units.X)} × {math.round(units.Y)}`
end

local function channel(value: number): number
	return math.clamp(math.round(value * 255), 0, 255)
end

local function draw(wanted: Wanted): EditableImage?
	local preset = map_presets.presets[wanted.preset]
	local size = preset.size
	local scale = LONGEST / math.max(size.X, size.Y)
	local width = math.max(1, math.round(size.X * scale))
	local depth = math.max(1, math.round(size.Y * scale))

	local height_at = preset.build(wanted.seed)
	local paint = ground_paint.make_painter(preset.theme, wanted.seed)
	local water = preset.theme.water_color
	local pixels = buffer.create(width * depth * 4)
	local studs_per_pixel_x = size.X / width
	local studs_per_pixel_z = size.Y / depth
	local west = -size.X / 2
	local north = -size.Y / 2

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

			local depth_below = ground_levels.WATER_LEVEL - height
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

local function drain()
	if drawing then
		return
	end
	drawing = true
	task.spawn(function()
		while #queue > 0 do
			local wanted = table.remove(queue, 1) :: Wanted
			local key = key_of(wanted.preset, wanted.seed)
			local ok, result = pcall(draw, wanted)
			local image: EditableImage? = if ok then result else nil
			if image ~= nil then
				images[key] = image
			else
				warn(`the picture of {wanted.preset} could not be drawn: {if ok then "no memory for it" else result}`)
				failed[key] = true
			end
			queued[key] = nil
			drawn.fire(key)
		end
		drawing = false
	end)
end

-- The picture of `preset_name` from `seed`, if it has been drawn; otherwise asks for it to be.
local function image_of(preset_name: string, seed: number): EditableImage?
	local key = key_of(preset_name, seed)
	local image: EditableImage? = images[key]
	if image ~= nil or failed[key] == true or map_presets.presets[preset_name] == nil then
		return image
	end
	if queued[key] == nil then
		queued[key] = true
		table.insert(queue, { preset = preset_name, seed = seed })
		drain()
	end
	return nil
end

-- A component's hook for the picture of `preset_name` from `seed`: nil until it is drawn, and the picture once it is.
local function use_image(preset_name: string, seed: number): EditableImage?
	use_store.use_changes(function(redraw: () -> ()): () -> ()
		local key = key_of(preset_name, seed)
		return drawn.subscribe(function(done: string)
			if done == key then
				redraw()
			end
		end)
	end, { preset_name, seed } :: { any })
	return image_of(preset_name, seed)
end

return table.freeze({
	units_of = units_of,
	units_text = units_text,
	image_of = image_of,
	use_image = use_image,
})
