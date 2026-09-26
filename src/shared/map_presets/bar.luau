--!strict
-- A Beyond All Reason map (see bar_maps) as a map preset. What a lobby shows of it, its size, starts, start boxes and
-- metal, comes from the map's own numbers; its heights and textures are only decoded the first time the map is built or
-- painted, and its features module only read when its vents or reclaimables are asked for, so a preset costs nothing
-- until the map is played or pictured.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local world_scale = require(ReplicatedStorage.Shared.world_scale)
local bar_maps = require(ReplicatedStorage.Shared.bar_maps)
local map_types = require(ReplicatedStorage.Shared.map_types)

type BarMap = bar_maps.BarMap
type Fitted = bar_maps.Fitted
type Preset = map_types.Preset
type Theme = map_types.Theme
type StartBox = map_types.StartBox
type FixedMetalSpot = map_types.FixedMetalSpot
type FixedReclaimable = map_types.FixedReclaimable

-- Ground that turns to the map's cliff where it is too steep for bots, whatever the texture says, so the routes read
-- the same as on every other map. Built ground, like a fortress wall or a dam, stays what it is.
local SOFT_GROUND: { [Enum.Material]: boolean } = {
	[Enum.Material.Grass] = true,
	[Enum.Material.LeafyGrass] = true,
	[Enum.Material.Ground] = true,
	[Enum.Material.Mud] = true,
	[Enum.Material.Sand] = true,
}

local function preset_of(map: BarMap): Preset
	-- laid down as it is, centred on (0, 0), one of the game's cells to each of the map's (as bar_maps.fit lays it)
	local size = Vector2.new(map.cells_x * world_scale.CELL_STUDS, map.cells_z * world_scale.CELL_STUDS)
	local function to_world(at: Vector2): Vector2
		return Vector2.new(-size.X / 2 + at.X * size.X, -size.Y / 2 + at.Y * size.Y)
	end

	-- decoded once, the first time anything needs the ground, and kept
	local fitted: Fitted? = nil
	local function fit(): Fitted
		if fitted == nil then
			fitted = bar_maps.fit(map)
		end
		return fitted :: Fitted
	end

	local starts: { Vector2 } = {}
	for _, at in map.starts do
		table.insert(starts, to_world(at))
	end

	local boxes: { StartBox } = {}
	for _, box in map.start_boxes do
		local a = to_world(box.min)
		local b = to_world(box.max)
		table.insert(boxes, {
			min = Vector2.new(math.min(a.X, b.X), math.min(a.Y, b.Y)),
			max = Vector2.new(math.max(a.X, b.X), math.max(a.Y, b.Y)),
		})
	end

	local metal: { FixedMetalSpot } = {}
	for _, spot in map.metal do
		table.insert(metal, {
			position = to_world(spot.at),
			multiplier = if spot.rich then map_types.RICH_MULTIPLIER else nil,
		})
	end

	-- what the map has lying on it, from its own archive
	local function vents(): { Vector2 }
		local out: { Vector2 } = {}
		for _, at in bar_maps.features_of(map.name).geovents do
			table.insert(out, to_world(at))
		end
		return out
	end
	local function reclaimables(): { FixedReclaimable }
		local out: { FixedReclaimable } = {}
		for _, feature in bar_maps.read_features(bar_maps.features_of(map.name)) do
			table.insert(out, {
				def_name = feature.def_name,
				position = to_world(feature.at),
				facing = feature.heading,
				metal = feature.metal,
				energy = feature.energy,
				buildpower = feature.buildpower,
			})
		end
		return out
	end

	-- the ground as the map's texture has it, and cliffs beyond its edges
	local fallback = map.materials[1]
	local theme: Theme = {
		ground = fallback,
		ground_patches = fallback,
		slope = fallback,
		cliff = map.cliff,
		shore = fallback,
		seabed = fallback,
		high_ground = nil,
		high_from = nil,
		colors = map.colors,
		water_color = map.water_color,
		paint = function(_seed: number): (number, number, number, boolean) -> Enum.Material?
			local material_at = fit().material_at
			return function(x: number, z: number, _height: number, too_steep: boolean): Enum.Material?
				local material = material_at(x, z)
				if material == nil or (too_steep and SOFT_GROUND[material] == true) then
					return map.cliff
				end
				return material
			end
		end,
	}

	return {
		name = map.name,
		display_name = map.display_name,
		description = `By {bar_maps.rights.credit(map.name)}, from Beyond All Reason`,
		source = "bar",
		size = size,
		build = function(_seed: number): (number, number) -> number
			return fit().height_at
		end,
		starts = starts,
		start_boxes = boxes,
		metal_layers = nil,
		metal_spots = metal,
		geo_spots = vents,
		reclaimables = reclaimables,
		wrecks = nil,
		theme = theme,
		conditions = { min_wind = map.min_wind, max_wind = map.max_wind, tidal_strength = map.tidal_strength },
	}
end

return table.freeze({
	preset_of = preset_of,
})
