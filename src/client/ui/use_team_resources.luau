--!strict
-- Your team's resources (Client.team_state) for a component, which renders again whenever the server says anew; or,
-- for a spectator, those of the team given.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local team_state = require(ReplicatedStorage.Client.team_state)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

type TeamResources = types.TeamResources

local function use_team_resources(): TeamResources
	return use_store.use_store(team_state.get, team_state.subscribe)
end

-- Team `team_id`'s resources as a spectator is told them.
local function use_watched_resources(team_id: number): TeamResources
	return use_store.use_store(function(): TeamResources
		return team_state.get_team(team_id)
	end, team_state.subscribe_teams, { team_id })
end

return table.freeze({
	use_team_resources = use_team_resources,
	use_watched_resources = use_watched_resources,
})
