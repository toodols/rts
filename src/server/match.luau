-- The match a lobby started on this server, if it started one. It overrides what the game would otherwise start with
-- (init.server.luau's map and seed, and the scavengers as config has them), which is what a game played straight from
-- this place, in Studio or on a public server, keeps.
--
-- A lobby starts a match by reserving a server of this place and teleporting its players into it together (see
-- lobby/server/launch.luau). It hands the match over twice:
--
-- - in a MemoryStore hash map under the reserved server's PrivateServerId, written by the lobby server before anyone
--   is sent, which is what this reads first: only a server can write it, so it can be trusted;
-- - as every player's teleport data, which is read only when the store cannot be, from the first of them to arrive.
--   It comes by way of the player's client, so it is only taken from a player the lobby place sent who is seated in
--   it, and it is a fallback: it is what would let a client change the map it is sent to.
--
-- A Studio test can hand a match in as well (`{ test = "match", match = {...} }`, see studio_tests.luau), so that
-- what a lobby start does can be played in Studio, where nobody can be teleported.
--
-- Seated players get a team each, numbered in side order so that a side's teams are together, and every team on a side
-- is allied with the rest of it, and has its player's resource bonus. A spectator gets none: they only watch. A scavengers match sets their pace from its
-- difficulty; any other mode turns them off. A campaign match is played on its mission's own map, and publishes the
-- mission as Workspace's campaign.MISSION_ATTRIBUTE; missions.luau puts it down. In Studio a campaign mission can be
-- played without the lobby by setting Workspace's `CampaignMission` (see missions.luau): its match seats whoever arrives
-- first.
-- The game waits to begin until every seated player has arrived, or ARRIVAL_SECONDS have passed (see lobby.luau).

local MemoryStoreService = game:GetService "MemoryStoreService"
local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local places = require(ReplicatedStorage.Shared.places)
local campaign = require(ReplicatedStorage.Shared.campaign)

local alliances = require(script.Parent.alliances)
local economy = require(script.Parent.economy)
local scavengers = require(script.Parent.scavengers)

type TeamId = types.TeamId
type Match = game_modes.Match
type Seat = game_modes.Seat

-- The lobby writes the match before sending anyone, but a read can still fail, so it is tried a few times.
local READ_ATTEMPTS = 5
local READ_RETRY_SECONDS = 1
-- How long to wait for the first player, to read the match from their teleport data when the store has none.
local TELEPORT_DATA_WAIT = 30
-- How long the game waits for the seated players who have not arrived before it gives up on them.
local ARRIVAL_SECONDS = 60

local current: Match? = nil
-- the team each seated player is given, by user id
local team_by_user: { [number]: TeamId } = {}
-- seated players who have been here, even if they have left since
local arrived_users: { [number]: boolean } = {}
local arrival_deadline = 0
-- who came only to watch, by user id
local spectating: { [number]: boolean } = {}
-- A mission played straight from Studio (see missions.luau) seats nobody in advance: the first player to arrive is
-- given this team, the first, which is kept for them until then.
local open_seat: TeamId? = nil

local function is_reserved(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

local function read_store(): Match?
	local got, store = pcall(MemoryStoreService.GetHashMap, MemoryStoreService, game_modes.MATCH_STORE)
	if got == false then
		warn(`there is no match store here: {store}`)
		return nil
	end
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

-- The match in `player`'s teleport data, if the lobby place sent them and they are seated in it.
local function match_from(player: Player): Match?
	local join = player:GetJoinData()
	if join.SourcePlaceId ~= places.LOBBY then
		return nil
	end
	local data = join.TeleportData
	if typeof(data) ~= "table" then
		return nil
	end
	local found = game_modes.decode(data.match)
	if found == nil then
		return nil
	end
	for _, seat in found.seats do
		if seat.user_id == player.UserId then
			return found
		end
	end
	return nil
end

-- Waits for the first player to arrive and reads the match from their teleport data.
local function read_teleport_data(): Match?
	local first = Players:GetPlayers()[1]
	if first == nil then
		local arrived: Player? = nil
		local connection = Players.PlayerAdded:Connect(function(player: Player)
			arrived = player
		end)
		local waited = 0
		while arrived == nil and waited < TELEPORT_DATA_WAIT do
			waited += task.wait()
		end
		connection:Disconnect()
		first = arrived
	end
	if first == nil then
		return nil
	end
	return match_from(first)
end

-- Seats the match's players, allies each side, gives each its bonus, sets whether allies' weapons hurt each other and
-- sets the scavengers up for it.
local function apply(match: Match)
	local mode = game_modes.get(match.mode) :: game_modes.Mode

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
	for index, seat in ordered do
		team_by_user[seat.user_id] = index
		economy.set_bonus(index, game_modes.bonus_of(match, seat.user_id))
		local first = first_of_side[seat.side]
		if first == nil then
			first_of_side[seat.side] = index
		else
			alliances.ally(first, index)
		end
	end
	alliances.set_ally_griefing(match.ally_griefing)

	if mode.kind == "scavengers" then
		local difficulty = game_modes.difficulty(mode.difficulty :: string)
		scavengers.set_enabled(true)
		if difficulty ~= nil then
			scavengers.set_pace(difficulty.pace)
			scavengers.set_health_multiplier(difficulty.health)
		end
	else
		scavengers.set_enabled(false)
	end
	-- a campaign mission is published for the clients, and put down once the map is built (see missions.luau)
	if mode.kind == "campaign" and mode.mission ~= nil then
		Workspace:SetAttribute(campaign.MISSION_ATTRIBUTE, mode.mission)
	end

	current = match
	arrival_deadline = os.clock() + ARRIVAL_SECONDS
end

-- A campaign match is always played on its mission's own map, whatever it says.
local function on_mission_map(match: Match): Match
	local mode = game_modes.get(match.mode) :: game_modes.Mode
	local mission = if mode.kind == "campaign" and mode.mission ~= nil then campaign.get(mode.mission) else nil
	if mission == nil or mission.preset == match.preset then
		return match
	end
	local moved = table.clone(match)
	moved.preset = mission.preset
	return table.freeze(moved)
end

-- The match a lobby would start for the campaign mission `mission_id`, with its one seat left open for whoever arrives
-- first, for a mission played straight from Studio (see missions.luau).
local function studio_match(mission_id: string): Match?
	local mode = game_modes.campaign_mode(mission_id)
	local mission = campaign.get(mission_id)
	if mode == nil or mission == nil then
		return nil
	end
	open_seat = 1
	return table.freeze({
		mode = mode.id,
		preset = mission.preset,
		seed = game_modes.DEFAULT_SEED,
		seats = table.freeze({}),
		bonuses = table.freeze({}),
		ally_griefing = false,
	})
end

-- Finds the match this server was started for and sets the game up for it: from `handed`, a match a Studio test passed
-- in, or else the store and then the teleport data of a reserved server, or else, in Studio, the campaign mission
-- `studio_mission` if one is asked for. Returns it, or nil for the usual game. Yields while it reads.
local function load(handed: any?, studio_mission: string?): Match?
	local found: Match? = nil
	if handed ~= nil then
		found = game_modes.decode(handed)
		if found == nil then
			warn "the match handed in is not one; playing the usual game"
			return nil
		end
	elseif RunService:IsStudio() == false and is_reserved() then
		found = read_store()
		if found == nil then
			warn "no match was left in the store for this reserved server; reading it from the teleport data"
			found = read_teleport_data()
		end
		if found == nil then
			warn "this is a reserved server, but no match came with it; playing the usual game"
			return nil
		end
	elseif RunService:IsStudio() and studio_mission ~= nil then
		found = studio_match(studio_mission)
	end
	if found ~= nil then
		found = on_mission_map(found)
		apply(found)
	end
	return found
end

-- The team the player `user_id` was seated on, or nil if they were not seated (or there is no match).
local function team_of_user(user_id: number): TeamId?
	return team_by_user[user_id]
end

local function team_of(player: Player): TeamId?
	local seat = open_seat
	if seat ~= nil and team_by_user[player.UserId] == nil then
		-- the first to arrive at a mission played straight from Studio takes its seat
		open_seat = nil
		team_by_user[player.UserId] = seat
	end
	return team_of_user(player.UserId)
end

-- Whether `player` came to this match only to watch.
local function is_spectator(player: Player): boolean
	return spectating[player.UserId] == true
end

-- How many teams the match seats, so that anyone else who turns up is given a team past them. A mission played
-- straight from Studio seats one, whoever arrives first.
local function seated_count(): number
	local match = current
	if match == nil then
		return 0
	end
	return math.max(game_modes.player_count(match.seats), if #match.seats == 0 then 1 else 0)
end

-- Called as each player arrives.
local function arrived(player: Player)
	if team_by_user[player.UserId] ~= nil then
		arrived_users[player.UserId] = true
	end
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
	team_of_user = team_of_user,
	is_spectator = is_spectator,
	seated_count = seated_count,
	arrived = arrived,
	is_awaiting = is_awaiting,
	update = update,
	get = get,
})
