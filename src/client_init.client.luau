local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_state = require(ReplicatedStorage.Shared.map_state)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local passability = require(ReplicatedStorage.Shared.passability)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local starts = require(ReplicatedStorage.Shared.starts)

local world_mod = require(ReplicatedStorage.Client.world)
local interpolation_mod = require(ReplicatedStorage.Client.interpolation)
local art_mod = require(ReplicatedStorage.Client.art)
local camera_mod = require(ReplicatedStorage.Client.camera)
local selection_mod = require(ReplicatedStorage.Client.selection)
local input_mod = require(ReplicatedStorage.Client.input)
local effects_mod = require(ReplicatedStorage.Client.effects)
local markers_mod = require(ReplicatedStorage.Client.markers)
local spot_markers_mod = require(ReplicatedStorage.Client.spot_markers)
local lobby_mod = require(ReplicatedStorage.Client.lobby)
local ui_mod = require(ReplicatedStorage.Client.ui)

local local_player = Players.LocalPlayer

-- The client builds the same ground the server did from the map it publishes, so ground height is known here
-- without the grid being sent. It catches up the same way when it joins and whenever the map is replaced: it builds
-- the map it sees and then asks for every edit made to that map so far. Edits labelled with any other map are dropped.
-- Units' ways are found here (`routes`), so what can be walked is kept up to date with the ground the way the server
-- keeps it (`deformation`).
local terrain_deformed: RemoteEvent = ReplicatedStorage.Shared.TerrainDeformed
terrain_deformed.OnClientEvent:Connect(function(generation: number, changes: { number })
	if generation ~= map_state.generation() or #changes == 0 then
		return
	end
	heightmap.apply_heights(changes)
	local across = heightmap.samples_across()
	local first_x, first_z, last_x, last_z = math.huge, math.huge, -math.huge, -math.huge
	for at = 1, #changes - 1, 2 do
		local cell_x = (changes[at] - 1) % across
		local cell_z = (changes[at] - 1) // across
		first_x = math.min(first_x, cell_x)
		first_z = math.min(first_z, cell_z)
		last_x = math.max(last_x, cell_x)
		last_z = math.max(last_z, cell_z)
	end
	-- a sample moves the surface over the four cells around it
	passability.refresh(first_x - 1, first_z - 1, last_x, last_z)
	pathfinder.refresh(first_x - 1, first_z - 1, last_x, last_z)
end)

local function build_published_map(): boolean
	local published = map_state.published()
	if published == nil or published.generation == map_state.generation() then
		return false
	end
	map_state.apply(published)
	passability.initialize()
	pathfinder.reset()
	terrain_deformed:FireServer(published.generation)
	return true
end

-- nothing below can run before there is ground to stand it on
while map_state.get() == nil do
	if build_published_map() == false then
		map_state.changed():Wait()
	end
end

-- Every model's meshes are fetched before anything is shown, so that nothing appears as an empty hitbox while its art
-- is still on its way.
local PRELOAD_TIMEOUT = 60
local preload_began = os.clock()
local not_built = art_mod.preload(PRELOAD_TIMEOUT)
if #not_built > 0 then
	warn(
		`art not built after {string.format("%.1f", os.clock() - preload_began)} seconds: {table.concat(not_built, ", ")}`
	)
end

world_mod.init()
interpolation_mod.init()
art_mod.init()
camera_mod.init()
selection_mod.init()
input_mod.init()
effects_mod.init()
markers_mod.init()
spot_markers_mod.init()
lobby_mod.init()
ui_mod.init_ui()

-- Opens the view over this player's starting position: the start they chose, or until they have, the one numbered as
-- their team is, once they have a team.
local function look_at_start()
	local slot = game_phase.start_of(local_player)
	if slot == nil then
		local team = local_player:GetAttribute "team"
		while typeof(team) ~= "number" do
			local_player:GetAttributeChangedSignal("team"):Wait()
			team = local_player:GetAttribute "team"
		end
		slot = team
	end
	local start = starts.center(slot :: number)
	camera_mod.look_at(Vector3.new(start.X, 0, start.Y))
end

-- A map replaced while playing: everything drawn from the old one is drawn again from the new, and the view goes to
-- the new start. Checked once more after connecting, in case it was replaced while the client was starting up.
local function follow_map()
	if build_published_map() then
		spot_markers_mod.rebuild()
		lobby_mod.rebuild()
		look_at_start()
	end
end
map_state.changed():Connect(follow_map)
follow_map()

look_at_start()

-- the view follows this player to the start they choose
local_player:GetAttributeChangedSignal(game_phase.START_ATTRIBUTE):Connect(look_at_start)

-- everything is built and drawn: the server may count this player as loaded in
local client_loaded: RemoteEvent = ReplicatedStorage.Shared.ClientLoaded
client_loaded:FireServer()
