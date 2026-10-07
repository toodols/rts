-- A mission's enemy zone on the ground (server/missions/counterattack.luau): the strip of the map's east end, from the
-- x the server publishes (Shared.mission_state's `zone_x`) to the edge, where the waves arrive and whatever the
-- player has is destroyed when they do. It is tinted red, tile by tile laid over the ground the way the tutorial's
-- marker's ring is, and its west edge is a brighter line, so that it reads from anywhere on the plateau. Nothing is drawn
-- while the attribute is not there, which is any game but that mission.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local mission_state = require(ReplicatedStorage.Shared.mission_state)

local world_fx = require(ReplicatedStorage.Client.world_fx)
local map_events = require(ReplicatedStorage.Client.map_events)

local palette = require(ReplicatedStorage.ClientShared.palette)

local COLOR = palette.danger
-- The tiles: how wide each is, how far above the ground its middle is lifted, and how much of the ground shows through.
local TILE = 4
local TILE_LIFT = 0.3
local TILE_THICKNESS = 0.2
local TILE_TRANSPARENCY = 0.82
-- The line along the west edge: its dashes, how thick, and how see-through.
local LINE_STEP = 2
local LINE_STYLE: world_fx.LineStyle = table.freeze({ lift = 0.4, thickness = 0.6, closed_corners = true })
local LINE_TRANSPARENCY = 0.25

local drawn: Model? = nil

local function make_part(name: string, parent: Instance): Part
	local part = world_fx.part(name)
	part.Color = COLOR
	part.Parent = parent
	return part
end

-- A tile with its middle at (x, z), tilted to lie along the ground there.
local function lay_tile(x: number, z: number, parent: Instance)
	local half = TILE / 2
	local east = heightmap.height_at(x + half, z)
	local west = heightmap.height_at(x - half, z)
	local south = heightmap.height_at(x, z + half)
	local north = heightmap.height_at(x, z - half)
	local along_x = Vector3.new(TILE, east - west, 0)
	local along_z = Vector3.new(0, south - north, TILE)
	local up = along_z:Cross(along_x).Unit
	local tile = make_part("Tile", parent)
	tile.Size = Vector3.new(along_x.Magnitude, TILE_THICKNESS, along_z.Magnitude)
	tile.CFrame = CFrame.fromMatrix(heightmap.ground_position(x, z) + up * TILE_LIFT, along_x.Unit, up)
	tile.Transparency = TILE_TRANSPARENCY
end

local function clear()
	if drawn ~= nil then
		drawn:Destroy()
		drawn = nil
	end
end

-- Draws the zone as the server has it now, or takes it away when there is none.
local function rebuild()
	clear()
	local zone_x = mission_state.zone_x()
	if zone_x == nil or heightmap.initialized() == false then
		return
	end
	local half_x, half_z = heightmap.half_extents()
	if zone_x >= half_x then
		return
	end
	local model = Instance.new "Model"
	model.Name = "EnemyZone"

	local x = zone_x + TILE / 2
	while x < half_x do
		local z = -half_z + TILE / 2
		while z < half_z do
			lay_tile(x, z, model)
			z += TILE
		end
		x += TILE
	end

	local edge = world_fx.ground_points(
		heightmap.ground_position(zone_x, -half_z),
		heightmap.ground_position(zone_x, half_z),
		LINE_STEP,
		"surface"
	)
	world_fx.lay_line(edge, LINE_STYLE, function(): Part
		local dash = make_part("Edge", model)
		dash.Transparency = LINE_TRANSPARENCY
		return dash
	end)

	model.Parent = world_fx.folder()
	drawn = model
end

local function init()
	mission_state.subscribe_zone(rebuild)
	map_events.on_rebuilt(rebuild)
	rebuild()
end

return table.freeze({
	init = init,
})
