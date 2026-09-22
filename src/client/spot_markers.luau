-- Draws the metal spots on the ground so players can see where extractors can go. A spot that
-- already has an extractor or blueprint on it is hidden, since there is nothing left to build there.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)

local world = require(ReplicatedStorage.Client.world)

type Marker = {
	part: Part,
	spot: metal_spots.Spot,
	shown: boolean,
}

local MARKER_COLOR = Color3.fromRGB(196, 206, 220)
local MARKER_DIAMETER = 7
local MARKER_HEIGHT = 0.2
local MARKER_LIFT = 0.25
local MARKER_TRANSPARENCY = 0.45
-- An extractor snaps onto its spot, so anything this close is sitting on it.
local OCCUPIED_RADIUS = 2

local markers: { Marker } = {}

local function effects_folder(): Instance
	local folder = Workspace:FindFirstChild "Effects"
	if folder ~= nil then
		return folder
	end
	return Workspace
end

local function make_marker(spot: metal_spots.Spot): Marker
	local part = Instance.new "Part"
	part.Name = "MetalSpot"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(MARKER_HEIGHT, MARKER_DIAMETER, MARKER_DIAMETER)
	part.Material = Enum.Material.Neon
	part.Color = MARKER_COLOR
	part.Transparency = MARKER_TRANSPARENCY
	-- a Cylinder part's flat faces point along X, so it is rolled to lie flat on the ground
	part.CFrame = CFrame.new(spot.center + Vector3.new(0, MARKER_LIFT, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	part.Parent = effects_folder()
	return { part = part, spot = spot, shown = true }
end

-- Whether some finished or unfinished spot-bound building stands on any position of `spot`.
local function occupied(spot: metal_spots.Spot): boolean
	for _, model in world.all() do
		if model:GetAttribute "kind" ~= "building" then
			continue
		end
		local def_name = model:GetAttribute "def_name"
		if typeof(def_name) ~= "string" then
			continue
		end
		local def = unit_defs.defs[def_name]
		if def == nil or def.requires_metal_spot ~= true then
			continue
		end
		local position = world.position_of(model)
		for _, valid in spot.positions do
			if Vector2.new(position.X - valid.X, position.Z - valid.Z).Magnitude <= OCCUPIED_RADIUS then
				return true
			end
		end
	end
	return false
end

local function update()
	for _, marker in markers do
		local should_show = occupied(marker.spot) == false
		if should_show ~= marker.shown then
			marker.shown = should_show
			marker.part.Parent = if should_show then effects_folder() else nil
		end
	end
end

-- Must run after the heightmap and metal spots have been initialised from the map seed.
local function init()
	for _, spot in metal_spots.all() do
		table.insert(markers, make_marker(spot))
	end
	RunService.RenderStepped:Connect(update)
end

return table.freeze({
	init = init,
})
