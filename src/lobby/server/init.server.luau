-- Lobby server entry point. Players come here first, make or join a lobby, and are sent on to a game server of their
-- own when its host starts it.
--
-- Clients ask for everything through `LobbyRequest` (see shared/protocol.luau) and are sent what they can see down
-- `LobbyState` whenever it may have changed. Changes are gathered and sent at most every PUSH_SECONDS, so a burst of
-- requests is one push.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local protocol = require(ReplicatedStorage.Lobby.protocol)

local lobbies = require(script.lobbies)
local directory = require(script.directory)
local launch = require(script.launch)

type Lobby = lobbies.Lobby
type LobbyView = protocol.LobbyView

local lobby_request: RemoteFunction = ReplicatedStorage.Lobby.LobbyRequest
local lobby_state: RemoteEvent = ReplicatedStorage.Lobby.LobbyState

local ACTIONS = protocol.ACTIONS
local PUSH_SECONDS = 0.1

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
	local ok, blocked = lobbies.can_start(lobby)
	return {
		id = lobby.id,
		host = lobby.host,
		mode = lobby.mode,
		preset = lobby.preset,
		seed = lobby.seed,
		visibility = lobby.visibility,
		seats = seats,
		starting = lobby.starting,
		blocked = if ok then nil else blocked,
	}
end

local function push()
	for _, player in Players:GetPlayers() do
		lobby_state:FireClient(player, {
			lobbies = directory.visible_to(player, mark_dirty),
			current = view_of(lobbies.of_user(player.UserId)),
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
			lobbies.close(lobby)
			mark_dirty()
		else
			lobbies.cancel_start(lobby)
			tell(lobby, reason or "The game couldn't be started")
		end
	end)
	return true, nil
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
	elseif action == ACTIONS.create then
		local lobby, err = lobbies.create(user_id, player.DisplayName)
		return lobby ~= nil, err
	elseif action == ACTIONS.join then
		return join(player, argument)
	elseif action == ACTIONS.leave then
		lobbies.leave(user_id)
		return true, nil
	elseif action == ACTIONS.set_map and typeof(argument) == "string" then
		return lobbies.set_map(user_id, argument)
	elseif action == ACTIONS.set_mode and typeof(argument) == "string" then
		return lobbies.set_mode(user_id, argument)
	elseif action == ACTIONS.set_visibility and typeof(argument) == "string" then
		return lobbies.set_visibility(user_id, argument)
	elseif action == ACTIONS.move and typeof(argument) == "number" then
		return lobbies.move(user_id, argument)
	elseif action == ACTIONS.start then
		return start(player)
	end
	return false, "That isn't something the lobby can do"
end

-- Someone sent here to join a lobby on this server is seated in it as they arrive, if it still has room for them.
local function on_player_added(player: Player)
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
		notices[player] = nil
		mark_dirty()
	end)

	directory.start(mark_dirty)

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
