-- The match a lobby started on this server, if it started one.
--
-- A lobby starts a match by reserving a server of this place and teleporting its players into it, having first left
-- the match - mode, map and who sits on which side - in a MemoryStore hash map under the reserved server's
-- PrivateServerId (see shared/game_modes.luau). This reads it back once, as the server starts. Any other server - a
-- public one, or Studio - has no match and plays as it always has.
--
-- Seated players get a team each, numbered in side order so that a side's teams take neighbouring starts, and every
-- team on a side is allied with the rest of it. A scavengers match sets their pace from its difficulty; any other
-- mode turns them off.

local MemoryStoreService = game:GetService "MemoryStoreService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local types = require(ReplicatedStorage.Shared.types)
local game_modes = require(ReplicatedStorage.Shared.game_modes)

local alliances = require(script.Parent.alliances)
local scavengers = require(script.Parent.scavengers)

type TeamId = types.TeamId
type Match = game_modes.Match
type Seat = game_modes.Seat

-- The match can reach the store a moment after the server does: the lobby writes it before teleporting, but a read
-- can still fail, so it is tried a few times.
local READ_ATTEMPTS = 5
local READ_RETRY_SECONDS = 1

local current: Match? = nil
-- the team each seated player is given, by user id
local team_by_user: { [number]: TeamId } = {}

local function is_reserved(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

local function read(): Match?
	local store = MemoryStoreService:GetHashMap(game_modes.MATCH_STORE)
	for attempt = 1, READ_ATTEMPTS do
		local ok, value = pcall(function()
			return store:GetAsync(game.PrivateServerId)
		end)
		if ok and value ~= nil then
			return game_modes.decode(value)
		end
		if ok == false then
			warn(`reading the match failed (attempt {attempt}): {value}`)
		end
		task.wait(READ_RETRY_SECONDS)
	end
	return nil
end

-- Reads the match, seats its players and sets the scavengers up for it. Returns it, or nil when this server was not
-- started by a lobby. Yields while it reads.
local function load(): Match?
	if RunService:IsStudio() or is_reserved() == false then
		return nil
	end
	local match = read()
	if match == nil then
		warn "this is a reserved server, but no match was left for it; playing the usual game"
		return nil
	end
	local mode = game_modes.get(match.mode) :: game_modes.Mode

	-- by side, and in the order the lobby seated them within a side
	local ordered = table.clone(match.seats)
	local seated_at: { [Seat]: number } = {}
	for index, seat in match.seats do
		seated_at[seat] = index
	end
	table.sort(ordered, function(a: Seat, b: Seat): boolean
		if a.side ~= b.side then
			return a.side < b.side
		end
		return seated_at[a] < seated_at[b]
	end)
	local first_of_side: { [number]: TeamId } = {}
	for index, seat in ordered do
		team_by_user[seat.user_id] = index
		local first = first_of_side[seat.side]
		if first == nil then
			first_of_side[seat.side] = index
		else
			alliances.ally(first, index)
		end
	end

	if mode.kind == "scavengers" then
		local difficulty = game_modes.difficulty(mode.difficulty :: string)
		scavengers.set_enabled(true)
		if difficulty ~= nil then
			scavengers.set_pace(difficulty.pace)
		end
	else
		scavengers.set_enabled(false)
	end

	current = match
	return match
end

-- The team `player` was seated on, or nil if they were not seated (or there is no match).
local function team_of(player: Player): TeamId?
	return team_by_user[player.UserId]
end

-- How many teams the match seats, so that anyone else who turns up is given a team past them.
local function seated_count(): number
	local match = current
	return if match ~= nil then #match.seats else 0
end

local function get(): Match?
	return current
end

return table.freeze({
	load = load,
	team_of = team_of,
	seated_count = seated_count,
	get = get,
})
