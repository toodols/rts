-- Player to team mapping: the team a lobby seated them on (see match.luau), or the next one free. More than one
-- player can be on a team, as pow's team_join puts them: they command everything it has and spend from one bank, as
-- one player would. Team ids are handed out in order, past the reserved ones (shared/teams.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local signal = require(ReplicatedStorage.Shared.signal)
local seating = require(ReplicatedStorage.Shared.seating)

local state = require(script.Parent.state)
local snapshot = require(script.Parent.snapshot)

type TeamId = types.TeamId

local team_by_player: { [Player]: TeamId } = {}
-- told of each player given a team, or moved to another
local team_changed = signal.new() :: signal.Signal<Player>
local next_team_id = teams.next_free(1)
-- ids below next_team_id handed back by teams taken down (`remove_team`), which are taken again first
local freed: { TeamId } = {}

-- The next team id free, taken: the lowest handed back, or else the next never taken.
local function take_team_id(): TeamId
	if #freed > 0 then
		table.sort(freed)
		return table.remove(freed, 1) :: TeamId
	end
	local team_id = next_team_id
	next_team_id = teams.next_free(team_id + 1)
	return team_id
end

-- Every player here on a team, in user id order.
local function seated(): { Player }
	local result = {}
	for player in team_by_player do
		table.insert(result, player)
	end
	table.sort(result, function(a: Player, b: Player): boolean
		return a.UserId < b.UserId
	end)
	return result
end

local function players_on_team(team_id: TeamId): { Player }
	local result = {}
	for player, id in team_by_player do
		if id == team_id then
			table.insert(result, player)
		end
	end
	table.sort(result, function(a: Player, b: Player): boolean
		return a.UserId < b.UserId
	end)
	return result
end

-- A team is named for its players. One nobody is on any more keeps the name it had.
local function name_team(team_id: TeamId)
	local team = state.get_team(team_id)
	local members = players_on_team(team_id)
	if team == nil or #members == 0 then
		return
	end
	local names = {}
	for _, member in members do
		table.insert(names, member.DisplayName)
	end
	team.name = table.concat(names, " & ")
end

-- Gives `player` team `wanted`, or the next team free when it is nil.
local function assign(player: Player, wanted: TeamId?): TeamId
	local existing = team_by_player[player]
	if existing ~= nil then
		return existing
	end
	local team_id = if wanted ~= nil then wanted else take_team_id()
	team_by_player[player] = team_id
	if state.get_team(team_id) == nil then
		state.create_team(team_id)
	end
	name_team(team_id)
	seating.set_team(player, team_id)
	team_changed.fire(player)
	return team_id
end

-- Puts `player` on team `team_id` from whatever team they were on, which is left with what it has.
local function move(player: Player, team_id: TeamId)
	local old = team_by_player[player]
	if old == team_id then
		return
	end
	team_by_player[player] = nil
	if old ~= nil then
		name_team(old)
	end
	assign(player, team_id)
end

-- Puts `player` on a team of their own, the next one free, and returns it.
local function split(player: Player): TeamId
	local old = team_by_player[player]
	team_by_player[player] = nil
	if old ~= nil then
		name_team(old)
	end
	return assign(player, nil)
end

-- A team with no player, made by hand: it takes the next team id, as a player joining would, and is named as given.
local function create_team(name: string): TeamId
	local team_id = take_team_id()
	local team = state.create_team(team_id)
	team.name = name
	return team_id
end

-- Keeps the first `count` teams for players a lobby seated, so that nobody else is given one of them.
local function reserve(count: number)
	next_team_id = teams.next_free(math.max(next_team_id, count + 1))
	for index = #freed, 1, -1 do
		if freed[index] <= count then
			table.remove(freed, index)
		end
	end
end

-- Takes down team `team_id`, made by hand (`create_team`) and with nobody on it, once it has nothing left on the field,
-- and hands its id back to be taken again.
local function remove_team(team_id: TeamId)
	state.remove_team(team_id)
	table.insert(freed, team_id)
end

-- Tells `listener` of each player given a team, or moved to another, until the returned function is called.
local function on_team_changed(listener: (Player) -> ()): () -> ()
	return team_changed.subscribe(listener)
end

local function team_of(player: Player): TeamId?
	return team_by_player[player]
end

local function forget(player: Player)
	local team_id = team_by_player[player]
	team_by_player[player] = nil
	if team_id ~= nil then
		name_team(team_id)
	end
end

snapshot.keep("players", function()
	return { next_team_id = next_team_id, freed = freed }
end, function(saved)
	next_team_id = saved.next_team_id
	freed = saved.freed
end)

return table.freeze({
	assign = assign,
	move = move,
	split = split,
	create_team = create_team,
	reserve = reserve,
	remove_team = remove_team,
	team_of = team_of,
	on_team_changed = on_team_changed,
	forget = forget,
	players_on_team = players_on_team,
	seated = seated,
})
