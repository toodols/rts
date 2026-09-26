-- The match being played, if the game is one: what a lobby started on this server, a test handed in, or a campaign
-- mission played straight from Studio, each read into an ordinary Match first (match_sources.luau, and which is played
-- is session_config.luau's to say). A game played straight from this place, in Studio or on a public server, has none.
--
-- Seated players get a team each, numbered in side order so that a side's teams are together, and every team on a side
-- is allied with the rest of it, and has its player's resource bonus. A mode whose players share a team
-- (game_modes.Mode's `shares_team`, a mission played together as one team) seats its whole side on its first player's
-- team instead, with that player's bonus: they all command it (players.luau). A spectator gets none: they only watch. The
-- mode's rules are its own (game_modes.Mode): whether the scavengers play is its `difficulty`'s (which the session
-- reads, session_config.luau), and so is the pace and health they play at, which are set here.
--
-- The game waits to begin until every seated player has arrived, or ARRIVAL_SECONDS have passed (see pregame.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local game_phase = require(ReplicatedStorage.Shared.game_phase)

local alliances = require(script.Parent.alliances)
local economy = require(script.Parent.economy)
local scavengers = require(script.Parent.scavengers)

type TeamId = types.TeamId
type Match = game_modes.Match
type Seat = game_modes.Seat

-- How long the game waits for the seated players who have not arrived before it gives up on them.
local ARRIVAL_SECONDS = 60

local current: Match? = nil
-- the team each seated player is given, by user id
local team_by_user: { [number]: TeamId } = {}
-- seated players who have been here, even if they have left since
local arrived_users: { [number]: boolean } = {}
-- seated players who have been here and left, until they come back
local left_users: { [number]: boolean } = {}
local arrival_deadline = 0
-- who came only to watch, by user id
local spectating: { [number]: boolean } = {}
-- how many teams the match's players were seated on: one for each player, or one for each side that shares a team
local seated_teams = 0

-- Plays `match`, in place of whatever was loaded before: seats its players, allies each side, gives each its bonus,
-- sets whether allies' weapons hurt each other and the pace and health the scavengers play at, as its mode has them.
local function load(match: Match)
	local mode = game_modes.get(match.mode) :: game_modes.Mode
	table.clear(team_by_user)
	table.clear(arrived_users)
	table.clear(left_users)
	table.clear(spectating)

	-- by side, and in the order the lobby seated them within a side; spectators get no team
	local ordered: { Seat } = {}
	for _, seat in match.seats do
		if game_modes.is_spectator(seat) then
			spectating[seat.user_id] = true
		else
			table.insert(ordered, seat)
		end
	end
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
	local next_team: TeamId = 1
	for _, seat in ordered do
		local first = first_of_side[seat.side]
		if mode.shares_team and first ~= nil then
			team_by_user[seat.user_id] = first
			continue
		end
		local team_id = next_team
		next_team += 1
		team_by_user[seat.user_id] = team_id
		economy.set_bonus(team_id, game_modes.bonus_of(match, seat.user_id))
		if first == nil then
			first_of_side[seat.side] = team_id
		else
			alliances.ally(first, team_id)
		end
	end
	seated_teams = next_team - 1
	alliances.set_ally_griefing(match.ally_griefing)

	local difficulty = if mode.difficulty ~= nil then game_modes.difficulty(mode.difficulty) else nil
	if difficulty ~= nil then
		scavengers.set_pace(difficulty.pace)
		scavengers.set_health_multiplier(difficulty.health)
	end

	current = match
	arrival_deadline = os.clock() + ARRIVAL_SECONDS
end

-- The team the player `user_id` was seated on, or nil if they were not seated (or there is no match).
local function team_of(user_id: number): TeamId?
	return team_by_user[user_id]
end

-- Whether the player `user_id` came to this match only to watch.
local function is_spectator(user_id: number): boolean
	return spectating[user_id] == true
end

-- How many teams the match seats its players on, so that anyone else who turns up is given a team past them.
local function seated_count(): number
	return if current ~= nil then seated_teams else 0
end

-- Called as the player `user_id` arrives, which a seated player counts as having done from then on.
local function arrived(user_id: number)
	if team_by_user[user_id] ~= nil then
		arrived_users[user_id] = true
		left_users[user_id] = nil
	end
end

-- Called as the player `user_id` leaves.
local function left(user_id: number)
	if arrived_users[user_id] == true then
		left_users[user_id] = true
	end
end

-- Whether the seated player `user_id` has been here at all this game.
local function has_arrived(user_id: number): boolean
	return arrived_users[user_id] == true
end

-- Whether the seated player `user_id` is here now: arrived, and not left since.
local function is_here(user_id: number): boolean
	return arrived_users[user_id] == true and left_users[user_id] ~= true
end

-- The seated players still being waited for: not arrived yet, and not given up on. Spectators are not waited for.
local function awaited(): { Seat }
	local match = current
	local result: { Seat } = {}
	if match == nil or os.clock() >= arrival_deadline then
		return result
	end
	for _, seat in match.seats do
		if game_modes.is_spectator(seat) == false and arrived_users[seat.user_id] ~= true then
			table.insert(result, seat)
		end
	end
	return result
end

-- Whether the game is still waiting for anyone the lobby sent.
local function is_awaiting(): boolean
	return #awaited() > 0
end

-- Publishes who is still on their way. Returns whether that changed since the last time, so the game can look again at
-- whether everyone is ready.
local function update(): boolean
	local was = #game_phase.awaiting()
	local names = {}
	for _, seat in awaited() do
		table.insert(names, seat.name)
	end
	game_phase.set_awaiting(names)
	return #names ~= was
end

local function get(): Match?
	return current
end

return table.freeze({
	load = load,
	team_of = team_of,
	is_spectator = is_spectator,
	seated_count = seated_count,
	arrived = arrived,
	left = left,
	has_arrived = has_arrived,
	is_here = is_here,
	is_awaiting = is_awaiting,
	update = update,
	get = get,
})
