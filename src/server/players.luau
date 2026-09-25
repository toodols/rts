-- Player to team mapping: the team a lobby seated them on (see match.luau), or the next one free. More than one
-- player can be on a team, as pow's team_join puts them: they command everything it has and spend from one bank, as
-- one player would.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local state = require(script.Parent.state)

type TeamId = types.TeamId

local team_by_player: { [Player]: TeamId } = {}
local next_team_id = 1

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
	local team_id = next_team_id
	if wanted ~= nil then
		team_id = wanted
	else
		next_team_id += 1
	end
	team_by_player[player] = team_id
	if state.get_team(team_id) == nil then
		state.create_team(team_id)
	end
	name_team(team_id)
	player:SetAttribute("team", team_id)
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
	local team_id = next_team_id
	next_team_id += 1
	local team = state.create_team(team_id)
	team.name = name
	return team_id
end

-- Keeps the first `count` teams for players a lobby seated, so that nobody else is given one of them.
local function reserve(count: number)
	next_team_id = math.max(next_team_id, count + 1)
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

return table.freeze({
	assign = assign,
	move = move,
	split = split,
	create_team = create_team,
	reserve = reserve,
	team_of = team_of,
	forget = forget,
	players_on_team = players_on_team,
})
