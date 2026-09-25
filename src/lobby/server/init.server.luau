-- Lobby server entry point. Players come here first, make or join a lobby, and are sent on to a game server of their
-- own when its host starts it; or they play a campaign mission, and are sent on to one alone (see missions.luau), or
-- make a co-op lobby for one, which is started like any other lobby.
--
-- Clients ask for everything through `LobbyRequest` (see shared/protocol.luau) and are sent what they can see down
-- `LobbyState` whenever it may have changed. Changes are gathered and sent at most every PUSH_SECONDS, so a burst of
-- requests is one push.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local developers = require(ReplicatedStorage.Shared.developers)
local campaign = require(ReplicatedStorage.Shared.campaign)
local places = require(ReplicatedStorage.Shared.places)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local lobbies = require(script.lobbies)
local directory = require(script.directory)
local launch = require(script.launch)
local missions = require(script.missions)
local skins = require(script.skins)

type Lobby = lobbies.Lobby
type LobbyView = protocol.LobbyView

local lobby_request: RemoteFunction = ReplicatedStorage.Lobby.LobbyRequest
local lobby_state: RemoteEvent = ReplicatedStorage.Lobby.LobbyState

local ACTIONS = protocol.ACTIONS
local PUSH_SECONDS = 0.1
local STUDIO_MISSION = "Campaign missions can only be launched on a live server. In Studio, set the game place's "
	.. `Workspace attribute CampaignMission = "tutorial" and press Play`

local dirty = false
-- told to each player with their next push, and then forgotten
local notices: { [Player]: string } = {}

local function mark_dirty()
	dirty = true
end

local function view_of(lobby: Lobby?): LobbyView?
	if lobby == nil then
		return nil
	end
	local seats = {}
	for _, seat in lobby.seats do
		table.insert(seats, { user_id = seat.user_id, name = seat.name, side = seat.side })
	end
	local ready = {}
	for user_id in lobby.ready do
		table.insert(ready, user_id)
	end
	local ok, blocked = lobbies.can_start(lobby)
	return {
		id = lobby.id,
		host = lobby.host,
		mode = lobby.mode,
		preset = lobby.preset,
		seed = lobby.seed,
		visibility = lobby.visibility,
		bonuses = table.clone(lobby.bonuses),
		ally_griefing = lobby.ally_griefing,
		end_mode = lobby.end_mode,
		seats = seats,
		ready = ready,
		starting = lobby.starting,
		teleporting = lobby.teleporting,
		blocked = if ok then nil else blocked,
	}
end

local function push()
	for _, player in Players:GetPlayers() do
		lobby_state:FireClient(player, {
			lobbies = directory.visible_to(player, mark_dirty),
			current = view_of(lobbies.of_user(player.UserId)),
			mission = missions.mission_of(player),
			notice = notices[player],
		})
	end
	table.clear(notices)
end

local function tell(lobby: Lobby, notice: string)
	for _, seat in lobby.seats do
		local player = Players:GetPlayerByUserId(seat.user_id)
		if player ~= nil then
			notices[player] = notice
		end
	end
	mark_dirty()
end

local function start(player: Player): (boolean, string?)
	local lobby, err = lobbies.begin_start(player.UserId)
	if lobby == nil then
		return false, err
	end
	local going: { Player } = {}
	for _, seat in lobby.seats do
		local member = Players:GetPlayerByUserId(seat.user_id)
		if member ~= nil then
			table.insert(going, member)
		end
	end
	local match = lobbies.to_match(lobby)
	mark_dirty()
	-- the host's request is answered now; how the start went is told to everyone in the lobby
	task.spawn(function()
		local ok, reason = launch.start(match, going)
		if ok then
			lobbies.mark_sent(lobby)
			mark_dirty()
		else
			lobbies.cancel_start(lobby)
			tell(lobby, reason or "The game couldn't be started")
		end
	end)
	return true, nil
end

-- Sends `player` alone to play the campaign mission `mission_id`. Someone in a lobby is refused rather than taken out
-- of it: the campaign screen is only reachable from the browser, so they would have to have asked from elsewhere.
local function play_mission(player: Player, mission_id: string): (boolean, string?)
	if lobbies.of_user(player.UserId) ~= nil then
		return false, "Leave your lobby to play a mission"
	end
	if RunService:IsStudio() then
		return false, STUDIO_MISSION
	end
	local match, err = missions.begin(player, mission_id)
	if match == nil then
		return false, err
	end
	mark_dirty()
	-- answered now; how the start went is in the player's state
	task.spawn(function()
		local ok, reason = launch.start(match, { player })
		if ok then
			missions.mark_sent(player)
		else
			missions.fail(player, reason or "The mission couldn't be started")
		end
		mark_dirty()
	end)
	return true, nil
end

-- Makes a co-op lobby hosted by `player` for the campaign mission `mission_id`, if they have got as far as it.
local function create_mission(player: Player, mission_id: string): (boolean, string?)
	if campaign.get(mission_id) == nil then
		return false, "There is no such mission"
	end
	if protocol.is_mission_open(missions.progress_of(player).completed, mission_id) == false then
		return false, "Finish the missions before this one first"
	end
	local lobby, err = lobbies.create(player.UserId, player.DisplayName, developers.is_developer(player), mission_id)
	return lobby ~= nil, err
end

local function join(player: Player, key: any): (boolean, string?)
	if typeof(key) ~= "string" then
		return false, "There is no such lobby"
	end
	local here = string.match(key, "^(.-)/") == game.JobId
	if here then
		local lobby = lobbies.get(string.match(key, "/(.*)$") :: string)
		if lobby == nil then
			return false, "That lobby is gone"
		end
		if directory.may_join(player, lobby.host, lobby.visibility) == false then
			return false, "That lobby is for the host's friends"
		end
		return lobbies.join(lobby.id, player.UserId, player.DisplayName)
	end
	local summary = directory.find_remote(key)
	if summary == nil then
		return false, "That lobby is gone"
	end
	if directory.may_join(player, summary.host, summary.visibility) == false then
		return false, "That lobby is for the host's friends"
	end
	if summary.players >= summary.capacity then
		return false, "That lobby is full"
	end
	return launch.go_to_lobby(player, summary.job_id, summary.lobby_id)
end

local function handle(player: Player, action: any, argument: any): (boolean, string?)
	local user_id = player.UserId
	if action == ACTIONS.refresh then
		return true, nil
	elseif action == ACTIONS.equip_skin and typeof(argument) == "string" then
		return skins.equip(player, argument)
	elseif missions.is_busy(player) then
		return false, "You are on your way to a mission"
	elseif action == ACTIONS.create then
		local lobby, err = lobbies.create(user_id, player.DisplayName, developers.is_developer(player))
		return lobby ~= nil, err
	elseif action == ACTIONS.join then
		return join(player, argument)
	elseif action == ACTIONS.leave then
		lobbies.leave(user_id)
		return true, nil
	elseif action == ACTIONS.set_map and typeof(argument) == "string" then
		return lobbies.set_map(user_id, argument, developers.is_developer(player))
	elseif action == ACTIONS.set_mode and typeof(argument) == "string" then
		return lobbies.set_mode(user_id, argument)
	elseif action == ACTIONS.set_visibility and typeof(argument) == "string" then
		return lobbies.set_visibility(user_id, argument)
	elseif
		action == ACTIONS.set_bonus
		and typeof(argument) == "table"
		and typeof(argument.user_id) == "number"
		and typeof(argument.percent) == "number"
	then
		if developers.is_developer(player) == false then
			return false, "Only a developer can give a bonus"
		end
		return lobbies.set_bonus(user_id, argument.user_id, argument.percent)
	elseif action == ACTIONS.set_ready and typeof(argument) == "boolean" then
		return lobbies.set_ready(user_id, argument)
	elseif action == ACTIONS.set_ally_griefing and typeof(argument) == "boolean" then
		return lobbies.set_ally_griefing(user_id, argument)
	elseif action == ACTIONS.set_end_mode and typeof(argument) == "string" then
		return lobbies.set_end_mode(user_id, argument)
	elseif action == ACTIONS.move and typeof(argument) == "number" then
		return lobbies.move(user_id, argument)
	elseif action == ACTIONS.start then
		return start(player)
	elseif action == ACTIONS.play_mission and typeof(argument) == "string" then
		return play_mission(player, argument)
	elseif action == ACTIONS.create_mission and typeof(argument) == "string" then
		return create_mission(player, argument)
	end
	return false, "That isn't something the lobby can do"
end

-- The mission someone sent back here from a finished one asked to go on to (`campaign_next`, see the game's
-- server/campaign_exit.luau), if they came from the game place and it names a mission. Whether it is open to them is
-- for `play_mission` to say, from their progress, as for any other ask to play one.
local function next_mission_request(player: Player): string?
	local join_data = player:GetJoinData()
	local data = join_data.TeleportData
	if join_data.SourcePlaceId ~= places.GAME or typeof(data) ~= "table" then
		return nil
	end
	local mission_id = data.campaign_next
	if typeof(mission_id) ~= "string" or campaign.get(mission_id) == nil then
		return nil
	end
	return mission_id
end

-- Someone sent here to join a lobby on this server is seated in it as they arrive, if it still has room for them, and
-- someone sent back from a mission they won to play the next is sent on to it once their progress has been read.
-- Everyone's campaign progress, and whether they are a developer, is read and published on them.
local function on_player_added(player: Player)
	local next_mission = next_mission_request(player)
	skins.player_added(player)
	task.spawn(function()
		developers.load(player)
		-- what they have equipped, once it is known whether they may wear a developer's skin
		skins.load(player)
		mark_dirty()
	end)
	task.spawn(function()
		local failed = missions.load(player)
		if failed ~= nil then
			notices[player] = failed
		end
		if next_mission ~= nil and player.Parent ~= nil then
			local ok, err = play_mission(player, next_mission)
			if ok == false then
				notices[player] = err or "Couldn't start the next mission"
			end
		end
		mark_dirty()
	end)
	local data = player:GetJoinData().TeleportData
	if typeof(data) == "table" and typeof(data.join) == "string" then
		local lobby = lobbies.get(data.join)
		if lobby ~= nil and directory.may_join(player, lobby.host, lobby.visibility) then
			local ok, err = lobbies.join(lobby.id, player.UserId, player.DisplayName)
			if ok == false then
				notices[player] = err or "Couldn't join that lobby"
			end
		else
			notices[player] = "That lobby is gone"
		end
	end
	mark_dirty()
end

local function init()
	-- nobody has an avatar here, only the menus
	Players.CharacterAutoLoads = false
	skins.init()

	lobby_request.OnServerInvoke = function(player: Player, action: any, argument: any): (boolean, string?)
		local ok, message = handle(player, action, argument)
		mark_dirty()
		return ok, message
	end

	Players.PlayerAdded:Connect(on_player_added)
	for _, player in Players:GetPlayers() do
		task.spawn(on_player_added, player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		lobbies.leave(player.UserId)
		missions.forget(player)
		notices[player] = nil
		mark_dirty()
	end)

	directory.start(mark_dirty)
	-- someone whose teleport to their game kept failing is back in the browser, and told why
	launch.init(function(player: Player, reason: string)
		lobbies.leave(player.UserId)
		missions.fail(player, `Couldn't get you into the game: {reason}`)
		notices[player] = `Couldn't get you into the game: {reason}`
		mark_dirty()
	end)

	task.spawn(function()
		while true do
			task.wait(PUSH_SECONDS)
			if dirty then
				dirty = false
				push()
			end
		end
	end)
end

init()
