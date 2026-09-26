-- What each team did over the game, for the end screen (client/ui/victory_screen.luau): the damage it dealt, what that
-- damage was worth, what it killed and lost, and the metal it made. Combat, the economy and reclaim report into it as
-- things happen, and once the game has ended it is published for every client to read (shared/match_report.luau).
--
-- Metal made is what the team brought in itself: its income, its converters and its reclaim. A refund, or metal an
-- ally shared, was made by someone else, or already counted.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local match_report = require(ReplicatedStorage.Shared.match_report)

local state = require(script.Parent.state)
local players = require(script.Parent.players)
local snapshot = require(script.Parent.snapshot)

type TeamId = types.TeamId

type Tally = {
	damage: number,
	-- what the damage took off, by the power (metal plus energy / 60) of what it hit
	destroyed: number,
	kills: number,
	lost: number,
	metal: number,
}

local tallies: { [TeamId]: Tally } = {}

local function tally_of(team: TeamId): Tally
	local tally = tallies[team]
	if tally == nil then
		tally = { damage = 0, destroyed = 0, kills = 0, lost = 0, metal = 0 }
		tallies[team] = tally
	end
	return tally
end

-- `team` has dealt `amount` damage to an enemy, worth `destroyed`.
local function dealt(team: TeamId, amount: number, destroyed: number)
	local tally = tally_of(team)
	tally.damage += amount
	tally.destroyed += destroyed
end

-- `team` has killed something of an enemy's that was finished.
local function killed(team: TeamId)
	tally_of(team).kills += 1
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
	match_report.publish(nil)
end

-- Every team that played but the scavengers, with what it did, whether it won, and whether a player played it.
local function publish()
	local winners = game_phase.winners()
	local rows: { match_report.TeamStats } = {}
	for team_id, team in state.all_teams() do
		if teams.is_playable(team_id) == false then
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
	table.sort(rows, function(a: match_report.TeamStats, b: match_report.TeamStats): boolean
		return a.team < b.team
	end)
	match_report.publish(rows)
end

-- Publishes the tallies the moment the game ends. A new map starts them over (`reset`, maps.luau's stages).
local function init()
	game_phase.on_phase(function(phase: game_phase.Phase)
		if phase == "ended" then
			publish()
		end
	end)
end

snapshot.keep("match_stats", function()
	return { tallies = tallies }
end, function(saved)
	tallies = saved.tallies
end)

return table.freeze({
	dealt = dealt,
	killed = killed,
	lost = lost,
	made_metal = made_metal,
	tally_for = tally_for,
	publish = publish,
	reset = reset,
	init = init,
})
