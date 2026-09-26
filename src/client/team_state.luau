--!strict
-- Your team's resources, as the server last said (TeamUpdated, a few times a second): the one place the client keeps
-- them, for the resource bar, the pilot's manual weapon and the tutorial's goals alike. A spectator, who has no team,
-- is told every team's instead (TeamsUpdated), and the resource bar shows theirs of whatever they select.
--
-- The server says from the moment the player joins, well before anything that shows them is up (the map and the art
-- load first), so `init` is called first thing as the client starts, and whatever comes later reads the latest.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local signal = require(ReplicatedStorage.Shared.signal)
local types = require(ReplicatedStorage.Shared.types)

type TeamResources = types.TeamResources

type TeamsEntry = types.TeamsEntry

local team_updated: RemoteEvent = ReplicatedStorage.Shared.TeamUpdated
local teams_updated: RemoteEvent = ReplicatedStorage.Shared.TeamsUpdated

-- What there is before the server has said: nothing, in storage that holds something, so that no fraction divides by
-- nothing.
local NOTHING: TeamResources = table.freeze({
	metal = 0,
	energy = 0,
	metal_capacity = 1,
	energy_capacity = 1,
	metal_income = 0,
	energy_income = 0,
	metal_revenue = 0,
	metal_expense = 0,
	energy_revenue = 0,
	energy_expense = 0,
})

local latest: TeamResources = NOTHING
local changed = signal.new() :: signal.Signal<TeamResources>
-- every team's, by id, for a spectator
local every_team: { [number]: TeamResources } = {}
local every_team_changed = signal.new() :: signal.Signal<()>

local function get(): TeamResources
	return latest
end

-- Team `team_id`'s resources, as a spectator was last told them.
local function get_team(team_id: number): TeamResources
	return every_team[team_id] or NOTHING
end

local function init()
	team_updated.OnClientEvent:Connect(function(resources: TeamResources)
		latest = table.freeze(resources)
		changed.fire(latest)
	end)
	teams_updated.OnClientEvent:Connect(function(entries: { TeamsEntry })
		local teams: { [number]: TeamResources } = {}
		for _, entry in entries do
			teams[entry.team] = table.freeze(entry.resources)
		end
		every_team = teams
		every_team_changed.fire()
	end)
end

return table.freeze({
	init = init,
	get = get,
	get_team = get_team,
	subscribe = changed.subscribe,
	subscribe_teams = every_team_changed.subscribe,
})
