-- Each player's skill, kept out of sight: an openskill rating (mu and sigma, see openskill/, from hex-game) with how many
-- games they have won, lost and drawn, on two ladders: duels (1v1) and small team games (2v2 to 5v5). Nothing here is
-- shown to anyone; it is only kept, for matchmaking to use one day.
--
-- A game is rated once it has ended (see shared/game_phase.luau), when it was a match a lobby started in a `rated` mode
-- (game_modes: the team games) with two sides, and each side had a player here at some point: which ladder it is on is
-- by how many the larger side seated, one for a duel and two to five for a team game. A player seated who never came is
-- not rated; one who left is, with their side. The winning side ranks above the other, and a game with no winners is a
-- draw.
--
-- The ratings are kept in the ratings store (server_shared/record_store.luau), one key a player, holding a Record for
-- each ladder they have played on. Every player's is read before any is written, and if one cannot be the game is not
-- rated, so that a failed read is never saved over. Where records are not kept (record_store.enabled: Studio) every
-- player starts fresh and nothing is written, so a test sees what a game would do (`on_rated`) and the real ratings
-- are never touched.
--
-- A new map is a new game, rated afresh once it ends (`reset`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local signal = require(ReplicatedStorage.Shared.signal)

local record_store = require(ServerScriptService.ServerShared.record_store)

local match = require(script.Parent.match)
local openskill = require(script.Parent.openskill)

type Seat = game_modes.Seat

export type Ladder = "duel" | "team"
export type Outcome = "won" | "lost" | "drew"

-- What is kept of a player on one ladder.
export type Record = {
	mu: number,
	sigma: number,
	wins: number,
	losses: number,
	draws: number,
}

-- What rating a game did.
export type Rated = {
	ladder: Ladder,
	-- by user id as a string
	players: { [string]: { outcome: Outcome, before: Record, after: Record } },
}

-- A game to rate: the players of each side who came, and each side's outcome.
type Game = {
	ladder: Ladder,
	sides: { { users: { number }, outcome: Outcome } },
}

-- How long a server shutting down waits for the ratings it is still writing.
local CLOSE_WAIT_SECONDS = 25
local LARGEST_DUEL = 1
local LARGEST_TEAM = 5

-- whether this server's game has been rated, or found not to be rated, already
local settled = false
-- how many games' ratings are still being worked out or written
local pending = 0
-- every game rated, once it has been
local rated_signal = signal.new() :: signal.Signal<Rated>

local function new_record(): Record
	local rating = openskill.Rating()
	return { mu = rating.mu, sigma = rating.sigma, wins = 0, losses = 0, draws = 0 }
end

-- A stored record, or a new one when nothing usable is stored.
local function decode_record(value: any): Record
	local record = new_record()
	if typeof(value) ~= "table" then
		return record
	end
	for key in record do
		if typeof(value[key]) == "number" then
			(record :: any)[key] = value[key]
		end
	end
	return record
end

-- The game that has just ended, if it is one to rate.
local function game_to_rate(): Game?
	local current = match.get()
	if current == nil then
		return nil
	end
	local mode = game_modes.get(current.mode)
	if mode == nil or mode.rated == false then
		return nil
	end
	local seated: { [number]: number } = {}
	local came: { [number]: { number } } = {}
	for _, seat: Seat in current.seats do
		if game_modes.is_spectator(seat) then
			continue
		end
		seated[seat.side] = (seated[seat.side] or 0) + 1
		if match.has_arrived(seat.user_id) then
			local users = came[seat.side] or {}
			table.insert(users, seat.user_id)
			came[seat.side] = users
		end
	end
	local side_ids: { number } = {}
	local largest = 0
	for side_id, count in seated do
		table.insert(side_ids, side_id)
		largest = math.max(largest, count)
	end
	if #side_ids ~= 2 or largest > LARGEST_TEAM then
		return nil
	end
	local ladder: Ladder = if largest <= LARGEST_DUEL then "duel" else "team"
	table.sort(side_ids)

	local winners = game_phase.winners()
	local result: Game = { ladder = ladder, sides = {} }
	for _, side_id in side_ids do
		local users = came[side_id]
		if users == nil then
			return nil
		end
		local won = false
		for _, user_id in users do
			local team_id = match.team_of(user_id)
			if team_id ~= nil and table.find(winners, team_id) ~= nil then
				won = true
			end
		end
		local outcome: Outcome = if #winners == 0 then "drew" elseif won then "won" else "lost"
		table.insert(result.sides, { users = users, outcome = outcome })
	end
	return result
end

-- Each player's ladders, what is stored of them by ladder.
local store = record_store.new({
	store = "ratings",
	decode = function(value: any): { [string]: any }
		return if typeof(value) == "table" then value else {}
	end,
	encode = function(ladders: { [string]: any }): any
		return ladders
	end,
})

-- Writes `record` as `user_id`'s on `ladder`, counting `outcome` on top of whatever count is stored. Yields.
local function save(user_id: number, ladder: Ladder, record: Record, outcome: Outcome): string?
	local _, problem = store.update(
		record_store.legacy_player_key(user_id),
		function(ladders: { [string]: any }): { [string]: any }
			local counts = decode_record(ladders[ladder])
			local changed = table.clone(ladders)
			changed[ladder] = {
				mu = record.mu,
				sigma = record.sigma,
				wins = counts.wins + if outcome == "won" then 1 else 0,
				losses = counts.losses + if outcome == "lost" then 1 else 0,
				draws = counts.draws + if outcome == "drew" then 1 else 0,
			}
			return changed
		end
	)
	return problem
end

-- Rates `played`: reads everyone's rating on its ladder, works out the new ones and writes them. Yields.
local function rate(played: Game)
	local persist = record_store.enabled()
	local before: { [number]: Record } = {}
	for _, side in played.sides do
		for _, user_id in side.users do
			if persist == false then
				before[user_id] = new_record()
				continue
			end
			local stored, reason = store.load(record_store.legacy_player_key(user_id))
			if stored == nil then
				warn(`not rating this game: could not read {user_id}'s rating: {reason}`)
				return
			end
			before[user_id] = decode_record(stored[played.ladder])
		end
	end

	-- openskill works the new ratings out in place
	local teams = {}
	local ranks = {}
	for _, side in played.sides do
		local team = {}
		for _, user_id in side.users do
			local record = before[user_id]
			table.insert(team, { mu = record.mu, sigma = record.sigma })
		end
		table.insert(teams, team)
		table.insert(ranks, if side.outcome == "lost" then 2 else 1)
	end
	openskill.Rate(teams, { rank = ranks })

	local rated: Rated = { ladder = played.ladder, players = {} }
	for side_index, side in played.sides do
		for user_index, user_id in side.users do
			local old = before[user_id]
			local rating = teams[side_index][user_index]
			local after: Record = {
				mu = rating.mu,
				sigma = rating.sigma,
				wins = old.wins + if side.outcome == "won" then 1 else 0,
				losses = old.losses + if side.outcome == "lost" then 1 else 0,
				draws = old.draws + if side.outcome == "drew" then 1 else 0,
			}
			rated.players[tostring(user_id)] = { outcome = side.outcome, before = old, after = after }
			if persist then
				local failed = save(user_id, played.ladder, after, side.outcome)
				if failed ~= nil then
					warn(`could not save {user_id}'s rating: {failed}`)
				end
			end
		end
	end
	rated_signal.fire(rated)
end

-- Rates the game once it has ended, if it is one to rate, and only the first time it ends.
local function on_phase(phase: game_phase.Phase)
	if settled or phase ~= "ended" then
		return
	end
	settled = true
	local played = game_to_rate()
	if played == nil then
		return
	end
	pending += 1
	task.spawn(function()
		local ok, err = pcall(rate, played)
		if ok == false then
			warn(`rating this game failed: {err}`)
		end
		pending -= 1
	end)
end

-- A new map is a new game, which is rated once it ends too.
local function reset()
	settled = false
end

-- Tells `listener` what rating each game did, once it has been rated and written, until the returned function is
-- called.
local function on_rated(listener: (Rated) -> ()): () -> ()
	return rated_signal.subscribe(listener)
end

local function init()
	game_phase.on_phase(on_phase)
	-- the last player leaving may be what ended the game, and the server closes behind them
	game:BindToClose(function()
		local deadline = os.clock() + CLOSE_WAIT_SECONDS
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return table.freeze({
	init = init,
	reset = reset,
	on_rated = on_rated,
})
