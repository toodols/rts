--!strict
-- What each player is told of their team's bank (TeamUpdated), for the resource bar: as they join, and a few times a
-- second after (the server's loop, `broadcast`). A spectator, who has no team, is told every team's (TeamsUpdated), and
-- is shown the team of whatever they select.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local seating = require(ReplicatedStorage.Shared.seating)
local teams = require(ReplicatedStorage.Shared.teams)

local remotes = require(ServerScriptService.ServerShared.remotes)

local state = require(script.Parent.state)
local players = require(script.Parent.players)

type Team = types.Team
type TeamResources = types.TeamResources
type TeamsEntry = types.TeamsEntry

local team_updated: RemoteEvent = ReplicatedStorage.Shared.TeamUpdated
local teams_updated: RemoteEvent = ReplicatedStorage.Shared.TeamsUpdated

-- What TeamUpdated carries of `team`.
local function snapshot(team: Team): TeamResources
	return {
		metal = team.metal,
		energy = team.energy,
		metal_capacity = team.metal_capacity,
		energy_capacity = team.energy_capacity,
		metal_income = team.metal_income,
		energy_income = team.energy_income,
		metal_revenue = team.metal_revenue,
		metal_expense = team.metal_expense,
		energy_revenue = team.energy_revenue,
		energy_expense = team.energy_expense,
	}
end

-- Every real team's bank, for a spectator.
local function every_team(): { TeamsEntry }
	local entries: { TeamsEntry } = {}
	for team_id, team in state.all_teams() do
		if team_id ~= teams.NEUTRAL then
			table.insert(entries, { team = team_id, resources = snapshot(team) })
		end
	end
	return entries
end

-- Tells `player` their team's bank, if they have a team, or every team's if they are a spectator. `entries` is every
-- team's, when it has been made already.
local function tell(player: Player, entries: { TeamsEntry }?): { TeamsEntry }?
	local team_id = players.team_of(player)
	if team_id == nil then
		if seating.is_spectator(player) == false then
			return entries
		end
		local all = entries or every_team()
		remotes.tell(teams_updated, player, all)
		return all
	end
	local team = state.get_team(team_id)
	if team ~= nil then
		remotes.tell(team_updated, player, snapshot(team))
	end
	return entries
end

local function send(player: Player)
	tell(player, nil)
end

-- Tells every player their team's bank, and every spectator every team's, made once for all of them and only if there
-- are any.
local function broadcast()
	local entries: { TeamsEntry }? = nil
	for _, player in Players:GetPlayers() do
		entries = tell(player, entries)
	end
end

return table.freeze({
	snapshot = snapshot,
	send = send,
	broadcast = broadcast,
})
