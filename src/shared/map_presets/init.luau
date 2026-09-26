--!strict
-- Every map the game can be played on, by name: the ones made for it (map_designs) and Beyond All Reason's (bar_maps, as
-- bar.luau makes them presets). A preset turns the seed into a height function over the whole map, in world
-- coordinates, and the heightmap samples it at every grid point. Each is a pure function of the seed, so the server and
-- the client build the same ground without it being sent.
--
-- Nothing changes a preset once it is made, nor the list of them: every one is frozen all the way down as it is added.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local world_scale = require(ReplicatedStorage.Shared.world_scale)
local deep_freeze = require(ReplicatedStorage.Shared.deep_freeze).deep_freeze
local bar_maps = require(ReplicatedStorage.Shared.bar_maps)
local map_types = require(ReplicatedStorage.Shared.map_types)
local map_designs = require(ReplicatedStorage.Shared.map_designs)

local bar = require(script.bar)

export type MetalLayer = map_types.MetalLayer
export type Theme = map_types.Theme
export type StartBox = map_types.StartBox
export type FixedMetalSpot = map_types.FixedMetalSpot
export type FixedReclaimable = map_types.FixedReclaimable
export type FixedWreck = map_types.FixedWreck
export type Preset = map_types.Preset
export type PresetSource = map_types.PresetSource

-- The map played where none is asked for, or the one asked for is not here (a BAR map its makers have not cleared is
-- only there in Studio, see bar_maps/rights.luau): one made for the game, which is always here.
local DEFAULT = "highlands"
-- The map a new lobby starts on, where it may pick it; DEFAULT where it may not.
local LOBBY_DEFAULT = "hooked"

local presets: { [string]: Preset } = {}

local function add(preset: Preset)
	assert(presets[preset.name] == nil, `two maps are called "{preset.name}"`)
	local cells_x = preset.size.X / world_scale.CELL_STUDS
	local cells_z = preset.size.Y / world_scale.CELL_STUDS
	-- only an even number of cells puts the map's edges, and so every cell, on the terrain's voxel grid about the middle,
	-- which is what lets a cell be drawn as exactly one column of voxels
	assert(cells_x % 2 == 0 and cells_z % 2 == 0, `{preset.name} is not an even number of cells across`)
	assert(#preset.starts > 0 and #preset.start_boxes > 0, `{preset.name} has nowhere to start`)
	presets[preset.name] = deep_freeze(preset)
end

for _, design in map_designs.ALL do
	add(design)
end
for _, map in bar_maps.MAPS do
	add(bar.preset_of(map))
end
table.freeze(presets)

-- The map called `name`, which has to be one.
local function get(name: string): Preset
	local preset = presets[name]
	assert(preset ~= nil, `there is no map called "{name}"`)
	return preset
end

-- Every map a lobby can pick, in the order it lists them: never a campaign mission's, and BAR's only for a `developer`.
-- The ones made for the game come first and then BAR's, each from smallest to largest.
local function lobby_choices(developer: boolean): { Preset }
	local result: { Preset } = {}
	for _, preset in presets do
		if preset.campaign_only ~= true and (developer or preset.source ~= "bar") then
			table.insert(result, preset)
		end
	end
	table.sort(result, function(a: Preset, b: Preset): boolean
		local a_bar, b_bar = a.source == "bar", b.source == "bar"
		if a_bar ~= b_bar then
			return b_bar
		end
		local area_a = a.size.X * a.size.Y
		local area_b = b.size.X * b.size.Y
		if area_a ~= area_b then
			return area_a < area_b
		end
		return a.display_name < b.display_name
	end)
	return result
end

-- Whether a lobby may pick the map called `name`, for a `developer` or not.
local function lobby_may_choose(name: string, developer: boolean): boolean
	local preset = presets[name]
	return preset ~= nil and table.find(lobby_choices(developer), preset) ~= nil
end

-- The map a new lobby hosted by a `developer`, or not, starts on.
local function lobby_default(developer: boolean): string
	return if lobby_may_choose(LOBBY_DEFAULT, developer) then LOBBY_DEFAULT else DEFAULT
end

return table.freeze({
	presets = presets,
	DEFAULT = DEFAULT,
	get = get,
	lobby_choices = lobby_choices,
	lobby_may_choose = lobby_may_choose,
	lobby_default = lobby_default,
})
