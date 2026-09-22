local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local starts = require(ReplicatedStorage.Shared.starts)

local world_mod = require(ReplicatedStorage.Client.world)
local interpolation_mod = require(ReplicatedStorage.Client.interpolation)
local camera_mod = require(ReplicatedStorage.Client.camera)
local selection_mod = require(ReplicatedStorage.Client.selection)
local input_mod = require(ReplicatedStorage.Client.input)
local effects_mod = require(ReplicatedStorage.Client.effects)
local markers_mod = require(ReplicatedStorage.Client.markers)
local spot_markers_mod = require(ReplicatedStorage.Client.spot_markers)
local ui_mod = require(ReplicatedStorage.Client.ui)

local local_player = Players.LocalPlayer

-- The client rebuilds the same heightmap the server generated from the shared seed, so ground
-- height is available locally without replicating the grid.
local function wait_for_seed(): number
	local seed = Workspace:GetAttribute "map_seed"
	while typeof(seed) ~= "number" do
		Workspace:GetAttributeChangedSignal("map_seed"):Wait()
		seed = Workspace:GetAttribute "map_seed"
	end
	return seed
end

-- The preset is set alongside the seed, so it is only a moment behind it at most.
local function wait_for_preset(): string
	local preset = Workspace:GetAttribute "map_preset"
	while typeof(preset) ~= "string" do
		Workspace:GetAttributeChangedSignal("map_preset"):Wait()
		preset = Workspace:GetAttribute "map_preset"
	end
	return preset
end

local seed = wait_for_seed()
heightmap.initialize(seed, wait_for_preset())
metal_spots.initialize(seed)

-- Explosions edit the ground. The server sends each edit as it is made, and every one made before this
-- client arrived when it is asked, which it does once it is listening.
local terrain_deformed: RemoteEvent = ReplicatedStorage.Shared.TerrainDeformed
terrain_deformed.OnClientEvent:Connect(function(changes: { number })
	heightmap.apply_heights(changes)
end)
terrain_deformed:FireServer()

world_mod.init()
interpolation_mod.init()
camera_mod.init()
selection_mod.init()
input_mod.init()
effects_mod.init()
markers_mod.init()
spot_markers_mod.init()
ui_mod.init_ui()

-- Open the view over this player's starting position.
local team = local_player:GetAttribute "team"
if typeof(team) ~= "number" then
	local_player:GetAttributeChangedSignal("team"):Wait()
	team = local_player:GetAttribute "team"
end

local start = starts.center(team :: number)
camera_mod.look_at(Vector3.new(start.X, 0, start.Y))
