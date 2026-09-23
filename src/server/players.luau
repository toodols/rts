-- Player to team mapping. One team per player: the team a lobby seated them on (see match.luau), or the next one
-- free.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local state = require(script.Parent.state)

type TeamId = types.TeamId

local team_by_player: { [Player]: TeamId } = {}
local next_team_id = 1

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
	local team = state.get_team(team_id)
	if team == nil then
		team = state.create_team(team_id)
	end
	-- a team is named for its player
	team.name = `{player.DisplayName}`
	player:SetAttribute("team", team_id)
	return team_id
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
	team_by_player[player] = nil
end

local function players_on_team(team_id: TeamId): { Player }
	local result = {}
	for player, id in team_by_player do
		if id == team_id then
			table.insert(result, player)
		end
	end
	return result
end

return table.freeze({
	assign = assign,
	create_team = create_team,
	reserve = reserve,
	team_of = team_of,
	forget = forget,
	players_on_team = players_on_team,
})
