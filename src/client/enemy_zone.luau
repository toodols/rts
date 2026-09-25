-- The counterattack's enemy zone on the ground (server/counterattack.luau): the strip of the map's east end, from the
-- x the server publishes (campaign.COUNTERATTACK_ATTRIBUTES.zone_x) to the edge, where the waves arrive and whatever the
-- player has is destroyed when they do. It is tinted red, tile by tile laid over the ground the way the tutorial's
-- marker's ring is, and its west edge is a brighter line, so that it reads from anywhere on the plateau. Nothing is drawn
-- while the attribute is not there, which is any game but that mission.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local campaign = require(ReplicatedStorage.Shared.campaign)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local ATTRIBUTE = campaign.COUNTERATTACK_ATTRIBUTES.zone_x
local COLOR = Color3.fromRGB(235, 72, 60)
-- The tiles: how wide each is, how far above the ground its middle is lifted, and how much of the ground shows through.
local TILE = 4
local TILE_LIFT = 0.3
local TILE_THICKNESS = 0.2
local TILE_TRANSPARENCY = 0.82
-- The line along the west edge: its dashes, how thick, and how see-through.
local LINE_STEP = 2
local LINE_THICKNESS = 0.6
local LINE_LIFT = 0.4
local LINE_TRANSPARENCY = 0.25

local drawn: Model? = nil

local function effects_folder(): Instance
	local folder = Workspace:FindFirstChild "Effects"
	if folder ~= nil then
		return folder
	end
	return Workspace
end

local function make_part(name: string, parent: Instance): Part
	local part = Instance.new "Part"
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
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
	local zone_x = Workspace:GetAttribute(ATTRIBUTE)
	if typeof(zone_x) ~= "number" or heightmap.initialized() == false then
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

	local previous: Vector3? = nil
	local z = -half_z
	while z <= half_z do
		local point = heightmap.ground_position(zone_x, z) + Vector3.new(0, LINE_LIFT, 0)
		if previous ~= nil then
			local dash = make_part("Edge", model)
			dash.Size = Vector3.new(LINE_THICKNESS, LINE_THICKNESS, (point - previous).Magnitude + LINE_THICKNESS)
			dash.CFrame = CFrame.lookAt((previous + point) / 2, point)
			dash.Transparency = LINE_TRANSPARENCY
		end
		previous = point
		z += LINE_STEP
	end

	model.Parent = effects_folder()
	drawn = model
end

local function init()
	Workspace:GetAttributeChangedSignal(ATTRIBUTE):Connect(rebuild)
	rebuild()
end

return table.freeze({
	init = init,
	rebuild = rebuild,
})
