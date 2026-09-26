-- Draws the metal spots and geothermal vents on the ground so players can see where extractors and geothermal plants
-- can go. A vent also steams, as BAR's do. A spot that already has something built or being built on it is hidden,
-- since there is nothing left to build there.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local spots = require(ReplicatedStorage.Shared.spots)
local placement_rules = require(ReplicatedStorage.Shared.placement_rules)

local world = require(ReplicatedStorage.Client.world)
local world_fx = require(ReplicatedStorage.Client.world_fx)
local map_events = require(ReplicatedStorage.Client.map_events)
local occupants = require(ReplicatedStorage.Client.occupants)

local palette = require(ReplicatedStorage.ClientShared.palette)

type Spot = spots.Spot

type Marker = {
	part: Part,
	spot: Spot,
	shown: boolean,
}

local MARKER_COLOR = palette.metal
local MARKER_DIAMETER = 7
local MARKER_HEIGHT = 0.2
local MARKER_LIFT = 0.25
local MARKER_TRANSPARENCY = 0.45
-- A vent is wider, the size of what stands on it, and green, as BAR draws its geothermal spots.
local VENT_COLOR = Color3.fromRGB(72, 220, 96)
local VENT_DIAMETER = 8
local STEAM_COLOR = Color3.fromRGB(170, 230, 180)
local markers: { Marker } = {}
-- whether something has come or gone since the markers were last shown or hidden
local stale = true

local function make_marker(spot: Spot, name: string, color: Color3, diameter: number): Marker
	local part = world_fx.part(name)
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(MARKER_HEIGHT, diameter, diameter)
	part.Color = color
	part.Transparency = MARKER_TRANSPARENCY
	part.CFrame = world_fx.lying_flat(spot.position + Vector3.new(0, MARKER_LIFT, 0))
	part.Parent = world_fx.folder()
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

-- Shows the markers of the spots nothing stands on, and hides the rest, once something has come or gone since.
local function update()
	if stale == false then
		return
	end
	stale = false
	for _, marker in markers do
		local should_show = placement_rules.spot_built_on(occupants.ALL, marker.spot.position, nil) == false
		if should_show ~= marker.shown then
			marker.shown = should_show
			marker.part.Parent = if should_show then world_fx.folder() else nil
		end
	end
end

local function mark_stale()
	stale = true
end

-- Must run after the heightmap, metal spots and geothermal vents have been initialised from the map seed.
-- Draws a marker on every spot of the map as it is now, in place of any drawn for the one before.
local function rebuild()
	for _, marker in markers do
		marker.part:Destroy()
	end
	table.clear(markers)
	for _, spot in spots.all "metal" do
		table.insert(markers, make_marker(spot, "MetalSpot", MARKER_COLOR, MARKER_DIAMETER))
	end
	for _, spot in spots.all "geo" do
		table.insert(markers, make_vent(spot))
	end
	stale = true
end

local function init()
	rebuild()
	map_events.on_rebuilt(rebuild)
	world.subscribe_listed(mark_stale)
	world.subscribe_removed(mark_stale)
	RunService.Heartbeat:Connect(update)
end

return table.freeze({
	init = init,
})
