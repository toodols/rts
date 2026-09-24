-- Draws the metal spots and geothermal vents on the ground so players can see where extractors and geothermal plants
-- can go. A vent also steams, as BAR's do. A spot that already has something built or being built on it is hidden,
-- since there is nothing left to build there.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local geo_spots = require(ReplicatedStorage.Shared.geo_spots)
local spots = require(ReplicatedStorage.Shared.spots)

local world = require(ReplicatedStorage.Client.world)

-- What a marker needs of a spot, metal or geothermal: where it is drawn and where a building on it stands.
type Spot = {
	center: Vector3,
	positions: { Vector3 },
}

type Marker = {
	part: Part,
	spot: Spot,
	shown: boolean,
}

local MARKER_COLOR = Color3.fromRGB(196, 206, 220)
local MARKER_DIAMETER = 7
local MARKER_HEIGHT = 0.2
local MARKER_LIFT = 0.25
local MARKER_TRANSPARENCY = 0.45
-- A vent is wider, the size of what stands on it, and green, as BAR draws its geothermal spots.
local VENT_COLOR = Color3.fromRGB(72, 220, 96)
local VENT_DIAMETER = 8
local STEAM_COLOR = Color3.fromRGB(170, 230, 180)
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

local function make_marker(spot: Spot, name: string, color: Color3, diameter: number): Marker
	local part = Instance.new "Part"
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(MARKER_HEIGHT, diameter, diameter)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Transparency = MARKER_TRANSPARENCY
	-- a Cylinder part's flat faces point along X, so it is rolled to lie flat on the ground
	part.CFrame = CFrame.new(spot.center + Vector3.new(0, MARKER_LIFT, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	part.Parent = effects_folder()
	return { part = part, spot = spot, shown = true }
end

local function make_vent(spot: Spot): Marker
	local marker = make_marker(spot, "GeoVent", VENT_COLOR, VENT_DIAMETER)
	local steam = Instance.new "Smoke"
	steam.Color = STEAM_COLOR
	steam.Opacity = 0.12
	steam.RiseVelocity = 4
	steam.Size = 2
	steam.Parent = marker.part
	return marker
end

-- Whether some finished or unfinished spot-bound building stands on any position of `spot`.
local function occupied(spot: Spot): boolean
	for _, model in world.all() do
		if model:GetAttribute "kind" ~= "building" then
			continue
		end
		local def_name = model:GetAttribute "def_name"
		if typeof(def_name) ~= "string" then
			continue
		end
		local def = unit_defs.defs[def_name]
		if def == nil or spots.for_def(def) == nil then
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

-- Must run after the heightmap, metal spots and geothermal vents have been initialised from the map seed.
-- Draws a marker on every spot of the map as it is now, in place of any drawn for the one before.
local function rebuild()
	for _, marker in markers do
		marker.part:Destroy()
	end
	table.clear(markers)
	for _, spot in metal_spots.all() do
		table.insert(markers, make_marker(spot, "MetalSpot", MARKER_COLOR, MARKER_DIAMETER))
	end
	for _, spot in geo_spots.all() do
		table.insert(markers, make_vent(spot))
	end
end

local function init()
	rebuild()
	RunService.RenderStepped:Connect(update)
end

return table.freeze({
	init = init,
	rebuild = rebuild,
})
