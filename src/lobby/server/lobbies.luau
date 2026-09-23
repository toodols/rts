-- The lobbies hosted on this server and the rules for changing them. Nothing here talks to Roblox: who may see or join
-- a lobby from another server is the directory's business, and starting one is launch's. A lobby lives on the server
-- its host made it on, and everyone in it is on that server.
--
-- A player is in one lobby at most. The host alone changes the settings and starts the game; when the host leaves, the
-- player seated longest takes over, and a lobby nobody is left in is gone.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local map_presets = require(ReplicatedStorage.Shared.map_presets)

type Mode = game_modes.Mode
type Seat = game_modes.Seat
type Match = game_modes.Match

export type Visibility = "public" | "friends"

export type Lobby = {
	id: string,
	host: number,
	mode: string,
	preset: string,
	seed: number,
	visibility: Visibility,
	-- in the order they joined
	seats: { Seat },
	-- set once the game is being started, after which nothing about the lobby can change
	starting: boolean,
}

local DEFAULT_PRESET = "hooked"

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
	for _, seat in lobby.seats do
		if seat.user_id == user_id then
			return seat
		end
	end
	return nil
end

local function count_on(lobby: Lobby, side: number): number
	local count = 0
	for _, seat in lobby.seats do
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

-- Seats everyone in `lobby` again for `mode`, keeping each on their side when it is still there and has room.
local function reseat(lobby: Lobby, mode: Mode)
	local kept: { Seat } = {}
	local moved: { Seat } = {}
	local counts: { [number]: number } = {}
	for _, seat in lobby.seats do
		local side = seat.side
		if mode.kind == "scavengers" then
			side = 1
		end
		local count = counts[side] or 0
		if side <= mode.sides and count < mode.per_side then
			counts[side] = count + 1
			seat.side = side
			table.insert(kept, seat)
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

local function create(host: number, host_name: string): (Lobby?, string?)
	if lobby_by_user[host] ~= nil then
		return nil, "You are already in a lobby"
	end
	made += 1
	local lobby: Lobby = {
		id = tostring(made),
		host = host,
		mode = game_modes.DEFAULT_MODE,
		preset = if map_presets.presets[DEFAULT_PRESET] ~= nil then DEFAULT_PRESET else map_presets.DEFAULT,
		seed = game_modes.DEFAULT_SEED,
		visibility = "public",
		seats = { { user_id = host, name = host_name, side = 1 } },
		starting = false,
	}
	lobbies[lobby.id] = lobby
	lobby_by_user[host] = lobby.id
	return lobby, nil
end

local function join(id: string, user_id: number, name: string): (boolean, string?)
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
	local mode = game_modes.get(lobby.mode) :: Mode
	local side = open_side(lobby, mode)
	if side == nil then
		return false, "That lobby is full"
	end
	table.insert(lobby.seats, { user_id = user_id, name = name, side = side })
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
	for index, seat in lobby.seats do
		if seat.user_id == user_id then
			table.remove(lobby.seats, index)
			break
		end
	end
	if #lobby.seats == 0 then
		lobbies[lobby.id] = nil
		return nil
	end
	if lobby.host == user_id then
		lobby.host = lobby.seats[1].user_id
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

local function set_mode(user_id: number, mode_id: string): (boolean, string?)
	local lobby, err = hosted(user_id)
	if lobby == nil then
		return false, err
	end
	local mode = game_modes.get(mode_id)
	if mode == nil then
		return false, "There is no such mode"
	end
	if #lobby.seats > mode.capacity then
		return false, `{mode.label} seats {mode.capacity}; there are {#lobby.seats} here`
	end
	lobby.mode = mode.id
	reseat(lobby, mode)
	return true, nil
end

local function set_map(user_id: number, preset: string): (boolean, string?)
	local lobby, err = hosted(user_id)
	if lobby == nil then
		return false, err
	end
	if map_presets.presets[preset] == nil then
		return false, "There is no such map"
	end
	lobby.preset = preset
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

-- Moves `user_id` to `side` of a team game, if it has room. Anyone may move themselves.
local function move(user_id: number, side: number): (boolean, string?)
	local lobby = of_user(user_id)
	if lobby == nil then
		return false, "You are not in a lobby"
	end
	if lobby.starting then
		return false, "The game is starting"
	end
	local mode = game_modes.get(lobby.mode) :: Mode
	if mode.kind ~= "teams" then
		return false, "Sides are only picked in a team game"
	end
	local seat = seat_of(lobby, user_id) :: Seat
	if seat.side == side then
		return true, nil
	end
	if side < 1 or side > mode.sides or count_on(lobby, side) >= mode.per_side then
		return false, "That team is full"
	end
	seat.side = side
	return true, nil
end

-- Whether `lobby` can start as it is, and why not when it cannot.
local function can_start(lobby: Lobby): (boolean, string?)
	return game_modes.can_start(game_modes.get(lobby.mode) :: Mode, lobby.seats)
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

local function to_match(lobby: Lobby): Match
	local seats = {}
	for _, seat in lobby.seats do
		table.insert(seats, { user_id = seat.user_id, name = seat.name, side = seat.side })
	end
	return { mode = lobby.mode, preset = lobby.preset, seed = lobby.seed, seats = seats }
end

-- Forgets the lobby and everyone in it, once they are on their way to the game.
local function close(lobby: Lobby)
	for _, seat in lobby.seats do
		if lobby_by_user[seat.user_id] == lobby.id then
			lobby_by_user[seat.user_id] = nil
		end
	end
	lobbies[lobby.id] = nil
end

return table.freeze({
	get = get,
	of_user = of_user,
	all = all,
	create = create,
	join = join,
	leave = leave,
	set_mode = set_mode,
	set_map = set_map,
	set_visibility = set_visibility,
	move = move,
	can_start = can_start,
	begin_start = begin_start,
	cancel_start = cancel_start,
	to_match = to_match,
	close = close,
})
