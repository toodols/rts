local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local game_phase = require(ReplicatedStorage.Shared.game_phase)
local starts = require(ReplicatedStorage.Shared.starts)

local world_mod = require(ReplicatedStorage.Client.world)
local building_walls_mod = require(ReplicatedStorage.Client.building_walls)
local interpolation_mod = require(ReplicatedStorage.Client.interpolation)
local art_mod = require(ReplicatedStorage.Client.art)
local camera_mod = require(ReplicatedStorage.Client.camera)
local selection_mod = require(ReplicatedStorage.Client.selection)
local input_router_mod = require(ReplicatedStorage.Client.input_router)
local command_state_mod = require(ReplicatedStorage.Client.command_state)
local command_input_mod = require(ReplicatedStorage.Client.command_input)
local build_mode_mod = require(ReplicatedStorage.Client.build_mode)
local pilot_mod = require(ReplicatedStorage.Client.pilot)
local effects_mod = require(ReplicatedStorage.Client.effects)
local atmospherics_mod = require(ReplicatedStorage.Client.atmospherics)
local wind_mod = require(ReplicatedStorage.Client.wind)
local sounds_mod = require(ReplicatedStorage.ClientShared.sounds)
local debris_mod = require(ReplicatedStorage.Client.debris)
local loose_pieces_mod = require(ReplicatedStorage.Client.loose_pieces)
local queue_paths_mod = require(ReplicatedStorage.Client.queue_paths)
local work_beams_mod = require(ReplicatedStorage.Client.work_beams)
local spot_markers_mod = require(ReplicatedStorage.Client.spot_markers)
local enemy_zone_mod = require(ReplicatedStorage.Client.enemy_zone)
local lobby_mod = require(ReplicatedStorage.Client.lobby)
local pings_mod = require(ReplicatedStorage.Client.pings)
local missions_mod = require(ReplicatedStorage.Client.missions)
local tutorial_mod = require(ReplicatedStorage.Client.tutorial)
local team_state_mod = require(ReplicatedStorage.Client.team_state)
local notifications_mod = require(ReplicatedStorage.Client.ui.notifications)
local ui_mod = require(ReplicatedStorage.Client.ui)
local map_events = require(ReplicatedStorage.Client.map_events)

local art_models = require(ReplicatedStorage.ClientShared.art_models)

local local_player = Players.LocalPlayer

-- the server says the team's resources, and can notify, from the moment this player joins, so both are listened for
-- before anything waits
team_state_mod.init()
notifications_mod.init()

-- the ground this client builds from the map the server publishes, and keeps up with (map_events); nothing below can
-- run before there is ground to stand it on
map_events.init()

-- Every model's meshes are fetched before anything is shown, so that nothing appears as an empty hitbox while its art
-- is still on its way.
local PRELOAD_TIMEOUT = 60
local preload_began = os.clock()
-- a mission's guide may want its pictures built first: they are the cards it teaches with
local mission_id = missions_mod.current()
local guide = if mission_id ~= nil then missions_mod.guide_of(mission_id) else nil
if guide ~= nil and guide.preload ~= nil then
	art_models.preload(guide.preload, PRELOAD_TIMEOUT)
end
local not_built = art_mod.preload(PRELOAD_TIMEOUT)
if #not_built > 0 then
	warn(
		`art not built after {string.format("%.1f", os.clock() - preload_began)} seconds: {table.concat(not_built, ", ")}`
	)
end

world_mod.init()
building_walls_mod.init()
interpolation_mod.init()
art_mod.init()
input_router_mod.init()
camera_mod.init()
selection_mod.init()
command_state_mod.init()
build_mode_mod.init()
command_input_mod.init()
pilot_mod.init()
effects_mod.init()
wind_mod.init()
atmospherics_mod.init()
sounds_mod.init_clicks()
loose_pieces_mod.init()
debris_mod.init()
queue_paths_mod.init()
work_beams_mod.init()
spot_markers_mod.init()
enemy_zone_mod.init()
lobby_mod.init()
pings_mod.init()
tutorial_mod.init()
ui_mod.init_ui()

-- Opens the view over this player's starting position: where a campaign mission puts them, or else where they chose
-- to start, or until they have, their start area's usual start, once they have one (`look_at_start` is called again
-- once they are first given one, below).
local function look_at_start()
	local mission_view = missions_mod.start_view()
	if mission_view ~= nil then
		camera_mod.look_at(mission_view)
		return
	end
	local chosen = game_phase.start_of(local_player)
	if chosen ~= nil then
		camera_mod.look_at(chosen)
		return
	end
	local box = game_phase.box_of(local_player)
	if box ~= nil then
		local spot = starts.default_spot(box)
		camera_mod.look_at(Vector3.new(spot.X, 0, spot.Y))
	end
end

-- A map replaced while playing: everything drawn from the old one is drawn again from the new (map_events), and then
-- the view goes to the new start.
map_events.on_rebuilt(look_at_start)

look_at_start()
-- a player given no box yet is looked at theirs as soon as they are
if game_phase.box_of(local_player) == nil then
	local stop_waiting: () -> ()
	stop_waiting = game_phase.box_changed(local_player, function()
		stop_waiting()
		look_at_start()
	end)
end

-- the view follows this player to the start they choose, and to a campaign mission's if the game turns out to be one
game_phase.start_changed(local_player, look_at_start)
missions_mod.subscribe(function(mission: string?)
	if mission ~= nil then
		look_at_start()
	end
end)

-- everything is built and drawn: the server may count this player as loaded in
local client_loaded: RemoteEvent = ReplicatedStorage.Shared.ClientLoaded
client_loaded:FireServer()
