--!strict
-- The lobbies hosted on this server and the rules for changing them. Nothing here talks to Roblox: who may see or join
-- a lobby from another server is the directory's business, and starting one is launch's. A lobby lives on the server
-- its host made it on, and everyone in it is on that server.
--
-- A player is in one lobby at most. The host alone changes the settings and starts the game; when the host leaves, the
-- player seated longest takes over, and a lobby nobody is left in is gone.
--
-- Besides its players a lobby has room for a few spectators (`game_modes.SPECTATOR_SIDE`), who come to the game with
-- everyone else and only watch. Anyone may move to watching, and back to a free seat. Someone who joins a lobby whose
-- seats are all taken watches, if there is room to.
--
-- A developer (shared/developers.luau), and nobody else, may give each player a resource bonus (see
-- game_modes.BONUS_MIN). It is theirs whatever side they are on, and goes with them when they leave. A developer's lobby
-- may also play a map from BAR, which nobody else is offered.
--
-- Every player but the host marks themselves ready, and the host can start only once they all have. Anything that
-- changes the game they agreed to - the mode, the map, ally griefing, the end mode, a bonus - takes everyone's back,
-- and moving to another side takes the mover's.
--
-- The host also picks whether allies' weapons hurt each other's things (game_modes.Match's `ally_griefing`); a new lobby
-- has it on, as BAR always does. And how a team game or a free for all is won (its `end_mode`); a new lobby has BAR's
-- default, a side is out once its commanders are dead. A scavenger game ignores it.
--
-- The host may also let in only players of some levels (campaign.level), a range from protocol.LEVEL_MIN to LEVEL_MAX
-- which a new lobby has all of. Someone outside it cannot join, and it cannot be set to leave out anyone already in.
-- A player's level is the caller's to say.
--
-- A co-op lobby (`create_mission`) plays a campaign mission together: its mode is the mission's campaign mode (its
-- hard mode's, for a hard mode's key), which seats everyone on one side, and its map the mission's. Neither can be
-- changed, and nor can the end mode, which a mission has its own of. Everything else about it, ally griefing, who may
-- join, who watches, being ready, is as in any lobby.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local map_presets = require(ReplicatedStorage.Shared.map_presets)
local campaign = require(ReplicatedStorage.Shared.campaign)

local protocol = require(ReplicatedStorage.Lobby.protocol)

type Mode = game_modes.Mode
type Seat = game_modes.Seat
type Match = game_modes.Match
type Visibility = protocol.Visibility

export type Lobby = {
	id: string,
	host: number,
	visibility: Visibility,
	-- the levels it lets in (see the top of this file)
	level_min: number,
	level_max: number,
	-- the game it will start, as it is set now; its seats are in the order the players joined
	match: Match,
	-- the players who have said they are ready, by user id
	ready: { [number]: boolean },
	-- set once the game is being started, after which nothing about the lobby can change
	starting: boolean,
	-- set once everyone has been sent to the game; the lobby stays, as that, until the last of them has left
	teleporting: boolean,
}

local lobbies: { [string]: Lobby } = {}
local lobby_by_user: { [number]: string } = {}
-- counted up for every lobby made, only to tell them apart within this server; the directory prefixes the job id
local made = 0

local function get(id: string): Lobby?
	return lobbies[id]
end

local function of_user(user_id: number): Lobby?
	local id = lobby_by_user[user_id]
	if id == nil then
		return nil
	end
	return lobbies[id]
end

local function all(): { [string]: Lobby }
	return lobbies
end

local function seat_of(lobby: Lobby, user_id: number): Seat?
	for _, seat in lobby.match.seats do
		if seat.user_id == user_id then
			return seat
		end
	end
	return nil
end

local function count_on(lobby: Lobby, side: number): number
	local count = 0
	for _, seat in lobby.match.seats do
		if seat.side == side then
			count += 1
		end
	end
	return count
end

-- The side a newcomer to `lobby` is seated on under `mode`: the emptiest, the first of those that tie. nil if every
-- side is full.
local function open_side(lobby: Lobby, mode: Mode): number?
	local best: number? = nil
	local best_count = math.huge
	for side = 1, mode.sides do
		local count = count_on(lobby, side)
		if count < mode.per_side and count < best_count then
			best = side
			best_count = count
		end
	end
	return best
end

-- Seats everyone in `lobby` again for `mode`, keeping each on their side when it is still there and has room. A
-- spectator goes on watching.
local function reseat(lobby: Lobby, mode: Mode)
	local moved: { Seat } = {}
	local counts: { [number]: number } = {}
	for _, seat in lobby.match.seats do
		if game_modes.is_spectator(seat) then
			continue
		end
		local side = seat.side
		local count = counts[side] or 0
		if side <= mode.sides and count < mode.per_side then
			counts[side] = count + 1
		else
			table.insert(moved, seat)
		end
	end
	for _, seat in moved do
		for side = 1, mode.sides do
			local count = counts[side] or 0
			if count < mode.per_side then
				counts[side] = count + 1
				seat.side = side
				break
			end
		end
	end
end

-- The campaign mission a co-op lobby plays, or nil for any other lobby.
local function mission_of(lobby: Lobby): string?
	local mode = game_modes.get(lobby.match.mode)
	return if mode ~= nil then mode.mission else nil
end

-- Makes a lobby hosted by `host`, playing the default mode and map, or the campaign mission `mission_id` names
-- (campaign.key: its id, or its hard mode's) together. Whether the host may play that mission, and whether they are a
-- `developer`, is for the caller to say.
local function create(host: number, host_name: string, developer: boolean, mission_id: string?): (Lobby?, string?)
	if lobby_by_user[host] ~= nil then
		return nil, "You are already in a lobby"
	end
	local seats = { { user_id = host, name = host_name, side = 1 } }
	local match = game_modes.new_match(game_modes.DEFAULT_MODE, map_presets.lobby_default(developer), seats)
	if mission_id ~= nil then
		local mission = campaign.parse_key(mission_id)
		local mission_match = game_modes.mission_match(mission_id, seats)
		if mission == nil or mission_match == nil then
			return nil, "There is no such mission"
		end
		if mission.coop == nil then
			return nil, `{mission.label} is only played alone`
		end
		match = mission_match
	end
	match.ally_griefing = true
	made += 1
	local lobby: Lobby = {
		id = tostring(made),
		host = host,
		visibility = "public",
		level_min = protocol.LEVEL_MIN,
		level_max = protocol.LEVEL_MAX,
		match = match,
		ready = {},
		starting = false,
		teleporting = false,
	}
	lobbies[lobby.id] = lobby
	lobby_by_user[host] = lobby.id
	return lobby, nil
end

-- Whether someone of `level` may join a lobby that lets in `level_min` to `level_max`, and why not if not.
local function level_refusal(level: number, level_min: number, level_max: number): string?
	if level < level_min or level > level_max then
		return `That lobby is for levels {level_min}-{level_max}`
	end
	return nil
end

-- `level` is the joiner's (campaign.level).
local function join(id: string, user_id: number, name: string, level: number): (boolean, string?)
	local lobby = lobbies[id]
	if lobby == nil then
		return false, "That lobby is gone"
	end
	if lobby_by_user[user_id] ~= nil then
		return lobby_by_user[user_id] == id, "You are already in a lobby"
	end
	if lobby.starting then
		return false, "That game is already starting"
	end
	local refused = level_refusal(level, lobby.level_min, lobby.level_max)
	if refused ~= nil then
		return false, refused
	end
	local mode = game_modes.get(lobby.match.mode) :: Mode
	local side = open_side(lobby, mode)
	-- with every seat taken, they watch
	if side == nil and game_modes.spectator_count(lobby.match.seats) < game_modes.SPECTATOR_CAPACITY then
		side = game_modes.SPECTATOR_SIDE
	end
	if side == nil then
		return false, "That lobby is full"
	end
	table.insert(lobby.match.seats, { user_id = user_id, name = name, side = side })
	lobby_by_user[user_id] = id
	return true, nil
end

-- Takes `user_id` out of whatever lobby they are in. Returns the lobby they left, if it is still there.
local function leave(user_id: number): Lobby?
	local lobby = of_user(user_id)
	lobby_by_user[user_id] = nil
	if lobby == nil then
		return nil
	end
	for index, seat in lobby.match.seats do
		if seat.user_id == user_id then
			table.remove(lobby.match.seats, index)
			break
		end
	end
	lobby.match.bonuses[tostring(user_id)] = nil
	lobby.ready[user_id] = nil
	if #lobby.match.seats == 0 then
		lobbies[lobby.id] = nil
		return nil
	end
	if lobby.host == user_id then
		lobby.host = lobby.match.seats[1].user_id
	end
	return lobby
end

-- The lobby `user_id` hosts and may change, or why they may not.
local function hosted(user_id: number): (Lobby?, string?)
	local lobby = of_user(user_id)
	if lobby == nil then
		return nil, "You are not in a lobby"
	end
	if lobby.host ~= user_id then
		return nil, "Only the host can change that"
	end
	if lobby.starting then
		return nil, "The game is starting"
	end
	return lobby, nil
end

-- The lobby `user_id` hosts and may change the game of, or why they may not: a co-op lobby's game is its mission's.
local function hosted_game(user_id: number): (Lobby?, string?)
	local lobby, err = hosted(user_id)
	if lobby == nil then
		return nil, err
	end
	local mission = campaign.get(mission_of(lobby) or "")
	if mission ~= nil then
		return nil, `Set by {mission.label}`
	end
	return lobby, nil
end

local function set_mode(user_id: number, mode_id: string): (boolean, string?)
	local lobby, err = hosted_game(user_id)
	if lobby == nil then
		return false, err
	end
	local mode = game_modes.get(mode_id)
	-- a campaign mode is started from the campaign screen, never picked by a host
	if mode == nil or mode.group == nil then
		return false, "There is no such mode"
	end
	local players = game_modes.player_count(lobby.match.seats)
	if players > mode.capacity then
		return false, `{mode.label} seats {mode.capacity}; there are {players} here`
	end
	lobby.match.mode = mode.id
	reseat(lobby, mode)
	table.clear(lobby.ready)
	return true, nil
end

-- `developer` is whether the host is one, which only the caller knows.
local function set_map(user_id: number, preset: string, developer: boolean): (boolean, string?)
	local lobby, err = hosted_game(user_id)
	if lobby == nil then
		return false, err
	end
	if map_presets.lobby_may_choose(preset, developer) == false then
		return false, "There is no such map"
	end
	lobby.match.preset = preset
	table.clear(lobby.ready)
	return true, nil
end

local function set_visibility(user_id: number, visibility: string): (boolean, string?)
	local lobby, err = hosted(user_id)
	if lobby == nil then
		return false, err
	end
	if visibility ~= "public" and visibility ~= "friends" then
		return false, "There is no such setting"
	end
	lobby.visibility = visibility
	return true, nil
end

-- Lets in only levels `min` to `max`, stepped to protocol.LEVEL_STEP and kept within the bounds. `level_of` says the
-- level of each user id in the lobby.
local function set_level_range(
	user_id: number,
	min: number,
	max: number,
	level_of: (user_id: number) -> number
): (boolean, string?)
	local lobby, err = hosted(user_id)
	if lobby == nil then
		return false, err
	end
	local function stepped(value: number): number
		local step = protocol.LEVEL_STEP
		return math.clamp(math.round(value / step) * step, protocol.LEVEL_MIN, protocol.LEVEL_MAX)
	end
	local low, high = stepped(min), stepped(max)
	if low > high then
		return false, "The lowest level has to be at most the highest"
	end
	for _, seat in lobby.match.seats do
		local level = level_of(seat.user_id)
		if level < low or level > high then
			return false, `{seat.name} is level {level}`
		end
	end
	lobby.level_min = low
	lobby.level_max = high
	return true, nil
end

-- Gives `player`, a player in the lobby `user_id` is in, a resource bonus of `percent`, which is kept within the
-- bounds. Whether `user_id` is a developer, and so may, is for the caller to say.
local function set_bonus(user_id: number, player: number, percent: number): (boolean, string?)
	local lobby = of_user(user_id)
	if lobby == nil then
		return false, "You are not in a lobby"
	end
	if lobby.starting then
		return false, "The game is starting"
	end
	local seat = seat_of(lobby, player)
	if seat == nil or game_modes.is_spectator(seat) then
		return false, "There is no such player"
	end
	local clamped = game_modes.clamp_bonus(percent)
	if clamped ~= 0 then
		lobby.match.bonuses[tostring(player)] = clamped
	else
		lobby.match.bonuses[tostring(player)] = nil
	end
	table.clear(lobby.ready)
	return true, nil
end

-- Marks `user_id` ready to start, or not. A spectator has nothing to be ready for, nor the host, who starts it.
local function set_ready(user_id: number, ready: boolean): (boolean, string?)
	local lobby = of_user(user_id)
	if lobby == nil then
		return false, "You are not in a lobby"
	end
	if lobby.starting then
		return false, "The game is starting"
	end
	local seat = seat_of(lobby, user_id) :: Seat
	if game_modes.is_spectator(seat) or lobby.host == user_id then
		return false, "Only a player can be ready"
	end
	if ready then
		lobby.ready[user_id] = true
	else
		lobby.ready[user_id] = nil
	end
	return true, nil
end

-- Any host may, a co-op lobby's too.
local function set_ally_griefing(user_id: number, enabled: boolean): (boolean, string?)
	local lobby, err = hosted(user_id)
	if lobby == nil then
		return false, err
	end
	if lobby.match.ally_griefing ~= enabled then
		lobby.match.ally_griefing = enabled
		table.clear(lobby.ready)
	end
	return true, nil
end

-- `value` has to be one of game_modes.END_MODES.
local function set_end_mode(user_id: number, value: string): (boolean, string?)
	local lobby, err = hosted_game(user_id)
	if lobby == nil then
		return false, err
	end
	local chosen = game_modes.end_mode(value)
	if chosen == nil then
		return false, "There is no such end mode"
	end
	if lobby.match.end_mode ~= chosen then
		lobby.match.end_mode = chosen :: game_modes.EndMode
		table.clear(lobby.ready)
	end
	return true, nil
end

-- Moves `user_id` to `side`, if it has room: to watching (`game_modes.SPECTATOR_SIDE`), to a side of a mode whose
-- players pick theirs, or in any other game from watching to a free seat, whichever of its sides `side` is. Anyone may
-- move themselves.
local function move(user_id: number, side: number): (boolean, string?)
	local lobby = of_user(user_id)
	if lobby == nil then
		return false, "You are not in a lobby"
	end
	if lobby.starting then
		return false, "The game is starting"
	end
	local mode = game_modes.get(lobby.match.mode) :: Mode
	if game_modes.has_side(mode, side) == false then
		return false, "There is no such side"
	end
	local seat = seat_of(lobby, user_id) :: Seat
	if seat.side == side then
		return true, nil
	end
	lobby.ready[user_id] = nil
	if side == game_modes.SPECTATOR_SIDE then
		if game_modes.spectator_count(lobby.match.seats) >= game_modes.SPECTATOR_CAPACITY then
			return false, "There is no room to watch"
		end
		seat.side = side
		return true, nil
	end
	if mode.picks_sides == false then
		-- only someone watching has a seat to take, and it is whichever is free
		if game_modes.is_spectator(seat) == false then
			return false, "Sides are only picked in a team game"
		end
		local free = open_side(lobby, mode)
		if free == nil then
			return false, "Every seat is taken"
		end
		seat.side = free
		return true, nil
	end
	if count_on(lobby, side) >= mode.per_side then
		return false, "That team is full"
	end
	seat.side = side
	return true, nil
end

-- Whether `lobby` can start as it is, and why not when it cannot: the mode has to have what it needs, and every player
-- but the host has to be ready.
local function can_start(lobby: Lobby): (boolean, string?)
	local ok, reason = game_modes.can_start(game_modes.get(lobby.match.mode) :: Mode, lobby.match.seats)
	if ok == false then
		return false, reason
	end
	local waiting: { string } = {}
	for _, seat in lobby.match.seats do
		if
			game_modes.is_spectator(seat) == false
			and seat.user_id ~= lobby.host
			and lobby.ready[seat.user_id] ~= true
		then
			table.insert(waiting, seat.name)
		end
	end
	if #waiting == 1 then
		return false, `Waiting for {waiting[1]} to be ready`
	elseif #waiting > 1 then
		return false, `Waiting for {#waiting} players to be ready`
	end
	return true, nil
end

-- Marks the lobby `user_id` hosts as starting and returns the match to start, or why it cannot be.
local function begin_start(user_id: number): (Lobby?, string?)
	local lobby, err = hosted(user_id)
	if lobby == nil then
		return nil, err
	end
	local ok, reason = can_start(lobby)
	if ok == false then
		return nil, reason
	end
	lobby.starting = true
	return lobby, nil
end

-- Lets a lobby whose start failed be changed and started again.
local function cancel_start(lobby: Lobby)
	lobby.starting = false
end

-- Marks the lobby as sent to its game. It is gone once everyone in it has left this server, as each `leave`s.
local function mark_sent(lobby: Lobby)
	lobby.teleporting = true
end

return table.freeze({
	get = get,
	of_user = of_user,
	all = all,
	mission_of = mission_of,
	create = create,
	join = join,
	leave = leave,
	set_mode = set_mode,
	set_map = set_map,
	set_visibility = set_visibility,
	set_level_range = set_level_range,
	level_refusal = level_refusal,
	set_bonus = set_bonus,
	set_ready = set_ready,
	set_ally_griefing = set_ally_griefing,
	set_end_mode = set_end_mode,
	move = move,
	can_start = can_start,
	begin_start = begin_start,
	cancel_start = cancel_start,
	mark_sent = mark_sent,
})
