-- What each team did over the game, for the end screen (client/ui/victory_screen.luau): the damage it dealt, what that
-- damage was worth, what it killed and lost, and the metal it made. Combat, the economy and reclaim report into it as
-- things happen, and once the game has ended it is published on Workspace, as JSON, for every client to read.
--
-- Metal made is what the team brought in itself: its income, its converters and its reclaim. A refund, or metal an
-- ally shared, was made by someone else, or already counted.

local HttpService = game:GetService "HttpService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local game_phase = require(ReplicatedStorage.Shared.game_phase)

local state = require(script.Parent.state)
local players = require(script.Parent.players)

type TeamId = types.TeamId

type Tally = {
	damage: number,
	-- what the damage took off, by the power (metal plus energy / 60) of what it hit
	destroyed: number,
	kills: number,
	lost: number,
	metal: number,
}

-- the Workspace attribute the end screen reads, and what shared/game_phase.luau's phase is published as
local ATTRIBUTE = "match_stats"
local PHASE_ATTRIBUTE = "phase"

local tallies: { [TeamId]: Tally } = {}

local function tally_of(team: TeamId): Tally
	local tally = tallies[team]
	if tally == nil then
		tally = { damage = 0, destroyed = 0, kills = 0, lost = 0, metal = 0 }
		tallies[team] = tally
	end
	return tally
end

-- `team` has dealt `dealt` damage to an enemy, worth `destroyed`, and `killed` says whether it finished it.
local function dealt(team: TeamId, amount: number, destroyed: number, killed: boolean)
	local tally = tally_of(team)
	tally.damage += amount
	tally.destroyed += destroyed
	if killed then
		tally.kills += 1
	end
end

-- `team` has lost something it had finished, to anything.
local function lost(team: TeamId)
	tally_of(team).lost += 1
end

-- `team` has made `amount` of metal itself.
local function made_metal(team: TeamId, amount: number)
	if amount > 0 then
		tally_of(team).metal += amount
	end
end

-- What `team` has done so far this game, for reading only.
local function tally_for(team: TeamId): Tally
	return table.freeze(table.clone(tally_of(team)))
end

-- Starts every tally over, as a new map does.
local function reset()
	table.clear(tallies)
	Workspace:SetAttribute(ATTRIBUTE, nil)
end

-- Every team that played but the scavengers, with what it did, whether it won, and whether a player played it.
local function publish()
	local winners = game_phase.winners()
	local rows = {}
	for team_id, team in state.all_teams() do
		if team_id == config.SCAVENGER_TEAM or team_id == 0 then
			continue
		end
		local tally = tally_of(team_id)
		table.insert(rows, {
			team = team_id,
			name = team.name,
			player = #players.players_on_team(team_id) > 0,
			won = table.find(winners, team_id) ~= nil,
			damage = math.floor(tally.damage + 0.5),
			destroyed = math.floor(tally.destroyed + 0.5),
			kills = tally.kills,
			lost = tally.lost,
			metal = math.floor(tally.metal + 0.5),
		})
	end
	table.sort(rows, function(a, b)
		return a.team < b.team
	end)
	Workspace:SetAttribute(ATTRIBUTE, HttpService:JSONEncode(rows))
end

-- Publishes the tallies the moment the game ends.
local function init()
	Workspace:GetAttributeChangedSignal(PHASE_ATTRIBUTE):Connect(function()
		if game_phase.phase() == "ended" then
			publish()
		end
	end)
end

return table.freeze({
	ATTRIBUTE = ATTRIBUTE,
	dealt = dealt,
	lost = lost,
	made_metal = made_metal,
	tally_for = tally_for,
	reset = reset,
	publish = publish,
	init = init,
})
