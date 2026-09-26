--!strict
-- Looking in on the brains from outside, for a command to print (`describe`) and a test or the AI arena to read
-- (`report`). The brains keep only what they play by; what they sent out, the fights they predicted and how many
-- fronts they fought on are kept here, as sorties.luau tells of them, the last SORTIES_KEPT of each kind of sortie, with
-- how many of its builders each has lost, until the team is no longer the AI's (`forget`); and a look over a team is
-- taken only when asked for.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)

local state = require(ServerScriptService.Server.state)
local deaths = require(ServerScriptService.Server.deaths)

local brains = require(script.Parent.brains)
local assignments = require(script.Parent.assignments)
local censuses = require(script.Parent.census)
local squads = require(script.Parent.squads)
local army = require(script.Parent.army)
local groups = require(script.Parent.groups)
local sorties = require(script.Parent.sorties)
local catalog = require(script.Parent.catalog)

type Entity = types.Entity
type TeamId = types.TeamId
type Brain = brains.Brain
type Sortie = sorties.Sortie

-- What has been seen of one brain.
type History = {
	brain: Brain,
	-- what it sent out, by kind: its waves, raids, hunts and strikes
	sent: { [string]: { Sortie } },
	-- how many fights it has asked the fight predictor about, and the seconds that took
	sims: number,
	sim_seconds: number,
	-- how many places it was attacking at once, summed over its thoughts, how many thoughts, and the most
	front_sum: number,
	front_samples: number,
	front_peak: number,
	-- how many of its builders, other than the commander, have been destroyed
	builders_lost: number,
}

local SORTIES_KEPT = 40

local histories: { [TeamId]: History } = {}

-- What has been seen of `brain`, begun afresh for a brain new to its team.
local function history_of(brain: Brain): History
	local history = histories[brain.team]
	if history == nil or history.brain ~= brain then
		history = {
			brain = brain,
			sent = { wave = {}, raid = {}, hunt = {}, strike = {} },
			sims = 0,
			sim_seconds = 0,
			front_sum = 0,
			front_samples = 0,
			front_peak = 0,
			builders_lost = 0,
		}
		histories[brain.team] = history
	end
	return history
end

-- Remembers `sortie`, keeping the last SORTIES_KEPT.
local function remember(list: { Sortie }, sortie: Sortie)
	table.insert(list, sortie)
	if #list > SORTIES_KEPT then
		table.remove(list, 1)
	end
end

-- A line about how team `team_id`'s AI is getting on, for a command to print.
local function describe(team_id: TeamId): string?
	local brain = brains.get(team_id)
	local team = state.get_team(team_id)
	if brain == nil or team == nil then
		return nil
	end
	local census = censuses.take(brain)
	return `{team.name} ({team_id}, {brain.profile.name}): {brain.line or "no line"}, army {army.mode_of(brain)} with {#census.army} worth {math.floor(
		squads.worth_of(census.army)
	)}, {#census.builders} builders ({history_of(brain).builders_lost} lost), {#census.factories} labs, {#census.extractors} extractors, metal {string.format(
		"%.1f",
		team.metal_income
	)}/s, energy {string.format("%.0f", team.energy_income)}/s, {brain.field.enemy_air_count} enemy aircraft`
end

-- What team `team_id`'s AI has sent out, for a test to look at: its waves, raids, hunts and strikes (the last
-- SORTIES_KEPT of each), how many raids are out, on how many fronts it has fought (on average over its thoughts, and at
-- most), what its army is doing, and what a wave would have to be worth to set out now.
local function report(team_id: TeamId): { [string]: any }?
	local brain = brains.get(team_id)
	local team = state.get_team(team_id)
	if brain == nil or team == nil then
		return nil
	end
	local history = history_of(brain)
	local census = censuses.take(brain)
	return {
		profile = brain.profile.name,
		line = brain.line,
		mode = army.mode_of(brain),
		waves = table.clone(history.sent.wave),
		waves_sent = brain.army.waves_sent,
		raids = table.clone(history.sent.raid),
		raids_out = groups.raids_out(brain),
		hunts = table.clone(history.sent.hunt),
		strikes = table.clone(history.sent.strike),
		fronts_mean = history.front_sum / math.max(1, history.front_samples),
		fronts_peak = history.front_peak,
		wave_needed = army.wave_needed(brain, censuses.read_economy(team, census, brain.profile)),
		retreating = assignments.count(brain, "retreat"),
		defenders = assignments.count(brain, "defend"),
		sims = history.sims,
		sim_seconds = history.sim_seconds,
	}
end

-- Keeps each brain's history from now on: what it sends out, how its waves end, what it predicts, and the builders it
-- loses: any but its commander destroyed other than by being taken off the map.
local function init()
	deaths.on_destroyed(function(entity: Entity, cause: deaths.DeathCause)
		local brain = brains.get(entity.team)
		if brain == nil or cause == "removed" or entity.kind ~= "unit" or entity.state ~= "active" then
			return
		end
		local role = catalog.role_of(entity.def_name)
		if role.builder and role.commander == false then
			history_of(brain).builders_lost += 1
		end
	end)
	sorties.on_sent(function(brain: Brain, kind: sorties.Kind, sortie: Sortie)
		remember(history_of(brain).sent[kind], sortie)
	end)
	sorties.on_ended(function(brain: Brain, how: sorties.WaveEnd)
		local waves = history_of(brain).sent.wave
		local last = waves[#waves]
		if last ~= nil and last.ended == nil then
			last.ended = how
		end
	end)
	sorties.on_predicted(function(brain: Brain, seconds: number)
		local history = history_of(brain)
		history.sims += 1
		history.sim_seconds += seconds
	end)
	sorties.on_fronts(function(brain: Brain, fronts: number)
		local history = history_of(brain)
		history.front_sum += fronts
		history.front_samples += 1
		history.front_peak = math.max(history.front_peak, fronts)
	end)
end

-- Forgets what was seen of team `team_id`'s AI.
local function forget(team_id: TeamId)
	histories[team_id] = nil
end

return table.freeze({
	init = init,
	describe = describe,
	report = report,
	forget = forget,
})
