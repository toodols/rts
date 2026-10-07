--!strict
-- Lobby server entry point. Players come here first, make or join a lobby, and are sent on to a game server of their
-- own when its host starts it; or they play a campaign mission, and are sent on to one alone (see mission_starts.luau),
-- or make a co-op lobby for one, which is started like any other lobby.
--
-- Clients ask for everything through `LobbyRequest` (see shared/protocol.luau) and are sent what they can see down
-- `LobbyState` whenever it may have changed. Changes are gathered and sent at most every PUSH_SECONDS, so a burst of
-- requests is one push.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local developers = require(ReplicatedStorage.Shared.developers)
local campaign = require(ReplicatedStorage.Shared.campaign)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local places = require(ReplicatedStorage.Shared.places)

local protocol = require(ReplicatedStorage.Lobby.protocol)

local lifecycle = require(ServerScriptService.ServerShared.lifecycle)
local campaign_session = require(ServerScriptService.ServerShared.campaign_session)
local skin_session = require(ServerScriptService.ServerShared.skin_session)
local keybind_session = require(ServerScriptService.ServerShared.keybind_session)
local developer_list = require(ServerScriptService.ServerShared.developer_list)
local remotes = require(ServerScriptService.ServerShared.remotes)
local teleports = require(ServerScriptService.ServerShared.teleports)

local lobbies = require(script.lobbies)
local directory = require(script.directory)
local launch = require(script.launch)
local mission_starts = require(script.mission_starts)

type Lobby = lobbies.Lobby
type LobbyView = protocol.LobbyView
-- What the server does for an action, answering whether it did it and why not if not.
type Handler = (player: Player, argument: any) -> (boolean, string?)

local lobby_request: RemoteFunction = ReplicatedStorage.Lobby.LobbyRequest
local lobby_state: RemoteEvent = ReplicatedStorage.Lobby.LobbyState

local PUSH_SECONDS = 0.1
-- A player asks for no more than this; a client asks as its player clicks.
local REQUEST_RATE = { per_second = 10, burst = 20 }
local STUDIO_MISSION = `To play a mission in Studio, set the game place's Workspace attribute CampaignMission = `
	.. `"tutorial" and press Play`

local dirty = false
-- told to each player with their next push, and then forgotten
local notices: { [Player]: string } = {}

local function mark_dirty()
	dirty = true
end

-- `player`'s level (campaign.level), from their campaign progress as it is now: a new player's until it is read.
local function level_of(player: Player): number
	return campaign.level(campaign_session.progress_of(player).unlocks)
end

-- The level of the player `user_id`, if they are on this server; a new player's if not.
local function level_of_user(user_id: number): number
	local player = Players:GetPlayerByUserId(user_id)
	return if player ~= nil then level_of(player) else protocol.LEVEL_MIN
end

-- Why `player` may not join a lobby yet, while their level is not known.
local function loading_refusal(player: Player): string?
	if campaign_session.status(player) == "loading" then
		return "Your campaign progress is still loading"
	end
	return nil
end

local function view_of(lobby: Lobby?): LobbyView?
	if lobby == nil then
		return nil
	end
	local ready = {}
	for user_id in lobby.ready do
		table.insert(ready, user_id)
	end
	local levels: { [string]: number } = {}
	for _, seat in lobby.match.seats do
		levels[tostring(seat.user_id)] = level_of_user(seat.user_id)
	end
	local ok, blocked = lobbies.can_start(lobby)
	return {
		id = lobby.id,
		host = lobby.host,
		visibility = lobby.visibility,
		level_min = lobby.level_min,
		level_max = lobby.level_max,
		levels = levels,
		match = game_modes.copy(lobby.match),
		ready = ready,
		starting = lobby.starting,
		teleporting = lobby.teleporting,
		blocked = if ok then nil else blocked,
	}
end

-- Sends every player their whole state, whatever changed: a lobby server holds a few dozen players and lists a few
-- hundred lobbies at most, so a state is small and a push a few times a second is cheap next to working out deltas.
local function push()
	for _, player in Players:GetPlayers() do
		remotes.tell(lobby_state, player, {
			lobbies = directory.visible_to(player, mark_dirty),
			current = view_of(lobbies.of_user(player.UserId)),
			mission = mission_starts.mission_of(player),
			notice = notices[player],
		})
	end
	table.clear(notices)
end

local function tell(lobby: Lobby, notice: string)
	for _, seat in lobby.match.seats do
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
	for _, seat in lobby.match.seats do
		local member = Players:GetPlayerByUserId(seat.user_id)
		if member ~= nil then
			table.insert(going, member)
		end
	end
	local match = game_modes.copy(lobby.match)
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

-- Sends `player` alone to play the campaign mission `mission_id` names (campaign.key: its id, or its hard mode's).
-- Someone in a lobby is refused rather than taken out of it: the campaign screen is only reachable from the browser,
-- so they would have to have asked from elsewhere.
local function play_mission(player: Player, mission_id: string): (boolean, string?)
	if lobbies.of_user(player.UserId) ~= nil then
		return false, "Leave your lobby to play a mission"
	end
	local refused = teleports.refusal(places.GAME)
	if refused ~= nil then
		return false, `{refused}. {STUDIO_MISSION}`
	end
	local match, err = mission_starts.begin(player, mission_id)
	if match == nil then
		return false, err
	end
	mark_dirty()
	-- answered now; how the start went is in the player's state
	task.spawn(function()
		local ok, reason = launch.start(match, { player })
		if ok then
			mission_starts.mark_sent(player)
		else
			mission_starts.fail(player, reason or "The mission couldn't be started")
		end
		mark_dirty()
	end)
	return true, nil
end

-- Makes a co-op lobby hosted by `player` for the campaign mission `mission_id` names (campaign.key: its id, or its hard
-- mode's), if they have got as far as it.
local function create_mission(player: Player, mission_id: string): (boolean, string?)
	local refused = mission_starts.refusal(player, mission_id)
	if refused ~= nil then
		return false, refused
	end
	local lobby, err = lobbies.create(player.UserId, player.DisplayName, developers.is_developer(player), mission_id)
	return lobby ~= nil, err
end

local function join(player: Player, key: string): (boolean, string?)
	local loading = loading_refusal(player)
	if loading ~= nil then
		return false, loading
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
		return lobbies.join(lobby.id, player.UserId, player.DisplayName, level_of(player))
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
	-- checked again on its server, as they arrive
	local refused = lobbies.level_refusal(level_of(player), summary.level_min, summary.level_max)
	if refused ~= nil then
		return false, refused
	end
	return launch.go_to_lobby(player, summary.job_id, summary.lobby_id)
end

-- What the server does for each action, given an argument protocol.ACTIONS has already said is one it takes.
local HANDLERS: { [string]: Handler } = {
	refresh = function(_player: Player, _argument: any): (boolean, string?)
		return true, nil
	end,
	create = function(player: Player, _argument: any): (boolean, string?)
		local lobby, err = lobbies.create(player.UserId, player.DisplayName, developers.is_developer(player))
		return lobby ~= nil, err
	end,
	join = join,
	leave = function(player: Player, _argument: any): (boolean, string?)
		lobbies.leave(player.UserId)
		return true, nil
	end,
	set_map = function(player: Player, preset: string): (boolean, string?)
		return lobbies.set_map(player.UserId, preset, developers.is_developer(player))
	end,
	set_mode = function(player: Player, mode_id: string): (boolean, string?)
		return lobbies.set_mode(player.UserId, mode_id)
	end,
	set_visibility = function(player: Player, visibility: string): (boolean, string?)
		return lobbies.set_visibility(player.UserId, visibility)
	end,
	set_level_range = function(player: Player, range: { min: number, max: number }): (boolean, string?)
		return lobbies.set_level_range(player.UserId, range.min, range.max, level_of_user)
	end,
	set_bonus = function(player: Player, bonus: { user_id: number, percent: number }): (boolean, string?)
		if developers.is_developer(player) == false then
			return false, "Only a developer can give a bonus"
		end
		return lobbies.set_bonus(player.UserId, bonus.user_id, bonus.percent)
	end,
	set_ready = function(player: Player, ready: boolean): (boolean, string?)
		return lobbies.set_ready(player.UserId, ready)
	end,
	set_ally_griefing = function(player: Player, enabled: boolean): (boolean, string?)
		return lobbies.set_ally_griefing(player.UserId, enabled)
	end,
	set_end_mode = function(player: Player, end_mode: string): (boolean, string?)
		return lobbies.set_end_mode(player.UserId, end_mode)
	end,
	move = function(player: Player, side: number): (boolean, string?)
		return lobbies.move(player.UserId, side)
	end,
	start = function(player: Player, _argument: any): (boolean, string?)
		return start(player)
	end,
	play_mission = play_mission,
	create_mission = create_mission,
	equip_skin = function(player: Player, skin: string): (boolean, string?)
		local outcome, why = skin_session.equip(player, skin)
		return outcome == "saved", why
	end,
}

-- What someone on their way to a mission may still ask for: only what leaves where they are going alone.
local WHILE_BUSY: { [string]: boolean } = { refresh = true, equip_skin = true }

local function handle(player: Player, asked: unknown, sent: unknown): (boolean, string?)
	local action, argument = protocol.read(asked, sent)
	if action == nil then
		return false, "That isn't something the lobby can do"
	end
	if WHILE_BUSY[action] ~= true and mission_starts.is_busy(player) then
		return false, "You are on your way to a mission"
	end
	return HANDLERS[action](player, argument)
end

-- Seats `player`, sent here to join the lobby `lobby_id` on this server, in it, if it still has room for them and lets
-- in their level.
local function join_on_arrival(player: Player, lobby_id: string)
	local lobby = lobbies.get(lobby_id)
	if lobby ~= nil and directory.may_join(player, lobby.host, lobby.visibility) then
		local ok, err = lobbies.join(lobby.id, player.UserId, player.DisplayName, level_of(player))
		if ok == false then
			notices[player] = err or "Couldn't join that lobby"
		end
	else
		notices[player] = "That lobby is gone"
	end
end

-- Someone sent here to join a lobby on this server is seated in it once their level is known.
local function on_player_added(player: Player)
	local data: any = player:GetJoinData().TeleportData
	local joining = if typeof(data) == "table" and typeof(data.join) == "string" then data.join else nil
	task.spawn(function()
		local loaded = campaign_session.wait_loaded(player)
		if player.Parent == nil then
			return
		end
		if loaded == false then
			notices[player] = "Couldn't load your campaign progress; showing a new player's"
		end
		if joining ~= nil then
			join_on_arrival(player, joining)
		end
		mark_dirty()
	end)
	mark_dirty()
end

local function on_player_removing(player: Player)
	lobbies.leave(player.UserId)
	mission_starts.forget(player)
	notices[player] = nil
	mark_dirty()
end

-- What is done as each player joins and leaves, in order (server_shared/lifecycle.luau): whether they are a developer,
-- their campaign progress, their skin and their keybinds, each the new player's at once and then what is stored, their
-- skin once whether they are a developer is known, since only a developer wears a developer's skin.
local PLAYER_STAGES: { lifecycle.Stage } = {
	{ joined = developer_list.joined, left = developer_list.left },
	{ joined = campaign_session.joined, left = campaign_session.left },
	{ joined = skin_session.joined, left = skin_session.left },
	{ joined = keybind_session.joined, left = keybind_session.left },
	{ joined = on_player_added, left = on_player_removing },
	{ left = directory.forget },
	{ left = teleports.forget },
	{ left = remotes.forget },
}

local function init()
	-- nobody has an avatar here, only the menus
	Players.CharacterAutoLoads = false
	-- what they may choose and wear is pushed again once whether they are a developer, and their skin, are known
	developer_list.on_published(mark_dirty)
	skin_session.on_worn(mark_dirty)
	-- and each player's level, shown in their lobby, once their progress is read or changes
	campaign_session.on_published(function()
		mark_dirty()
	end)

	remotes.answer(
		lobby_request,
		REQUEST_RATE,
		"Slow down",
		function(player: Player, action: unknown, argument: unknown): (boolean, string?)
			local ok, message = handle(player, action, argument)
			mark_dirty()
			return ok, message
		end
	)

	keybind_session.init()
	lifecycle.run(PLAYER_STAGES)

	teleports.init()
	directory.start(mark_dirty)
	-- someone whose teleport to their game kept failing is back in the browser, and told why
	launch.init(function(player: Player, reason: string)
		lobbies.leave(player.UserId)
		mission_starts.fail(player, `Couldn't get you into the game: {reason}`)
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
