--!strict
-- Defence in proportion, taken from BARb (a defence task sized to the threat it answers, behaviour.json
-- "thr_mod"."defence"): of the army waiting at home, as much as it takes goes to see an intruder off, the ones already
-- sent and then the nearest first, and the rest, and any wave out, carry on. How much it takes is the profile's
-- defend_rule's (`ENOUGH`): by "danger", as much as is worth its defend_share of the danger round the intruder; by
-- "sim", the fewest whose fight against what of the enemy is round it (predictions.luau's `enemies_near`) the fight
-- predictor says they win by its sim_defend_margin, found by halving. What waits at home is not enough when all of it
-- would not do.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

local danger_field = require(script.Parent.danger_field)
local brains = require(script.Parent.brains)
local assignments = require(script.Parent.assignments)
local censuses = require(script.Parent.census)
local squads = require(script.Parent.squads)
local predictions = require(script.Parent.predictions)

type Entity = types.Entity
type Brain = brains.Brain
type Census = censuses.Census
type Rule = ai_profiles.Rule

-- Of `line`, what is already sent and then what waits at home, the nearest first, the fewest that are enough to see
-- `enemy` off, by each defend_rule, with at least those already sent (the first `sent` of it); nil if all of it is not
-- enough. `share` is the profile's defend_share.
local ENOUGH: { [Rule]: (Brain, Census, { Entity }, number, Entity, number) -> { Entity }? } = table.freeze({
	danger = function(
		brain: Brain,
		_census: Census,
		line: { Entity },
		sent: number,
		enemy: Entity,
		share: number
	): { Entity }?
		local needed = danger_field.peak_near(brain.field, enemy.position, brain.profile.target_danger_radius) * share
		local defenders = table.move(line, 1, sent, 1, {})
		local worth = squads.worth_of(defenders)
		for index = sent + 1, #line do
			if worth >= needed and #defenders > 0 then
				break
			end
			table.insert(defenders, line[index])
			worth += unit_defs.power(line[index].def)
		end
		return if worth >= needed then defenders else nil
	end,
	sim = function(
		brain: Brain,
		census: Census,
		line: { Entity },
		sent: number,
		enemy: Entity,
		_share: number
	): { Entity }?
		local theirs = predictions.enemies_near(census, enemy.position)
		local count = predictions.fewest_that_win(brain, line, theirs, brain.profile.sim_defend_margin, sent)
		return if count ~= nil then table.move(line, 1, count, 1, {}) else nil
	end,
})

-- Lets every defender go back into the army.
local function recall(brain: Brain)
	assignments.release_all(brain, "defend", true)
end

-- Sends as much of `army` as it takes to see `enemy` off, by the profile's defend_rule with its defend_share `share`.
-- Returns the army less those it sent, or nil when what waits at home is not enough and the enemy has come near home,
-- for the whole army to come and see it off. An enemy by an extractor that what waits at home is not enough for is
-- left to the extractor's guard.
local function defend_in_proportion(
	brain: Brain,
	census: Census,
	army: { Entity },
	enemy: Entity,
	share: number
): { Entity }?
	local line: { Entity } = {}
	local waiting: { Entity } = {}
	local wave_out = brain.army.wave ~= nil
	for _, unit in army do
		local job = assignments.job_of(brain, unit.id)
		if job == "defend" then
			table.insert(line, unit)
		elseif wave_out == false or job ~= "wave" then
			table.insert(waiting, unit)
		end
	end
	local sent = #line
	table.sort(waiting, function(a, b): boolean
		return geometry.distance_2d(a.position, enemy.position) < geometry.distance_2d(b.position, enemy.position)
	end)
	table.move(waiting, 1, #waiting, sent + 1, line)
	local defenders = ENOUGH[brain.profile.defend_rule](brain, census, line, sent, enemy, share)
	if defenders == nil then
		recall(brain)
		if geometry.distance_2d(enemy.position, brain.home) <= brain.profile.defend_radius then
			return nil
		end
		return army
	end
	for _, unit in defenders do
		assignments.assign(brain, unit.id, { job = "defend" })
	end
	squads.send_all(brain, defenders, enemy.position, "fight", 0)
	local rest: { Entity } = {}
	for _, unit in army do
		if assignments.job_of(brain, unit.id) ~= "defend" then
			table.insert(rest, unit)
		end
	end
	return rest
end

return table.freeze({
	recall = recall,
	defend_in_proportion = defend_in_proportion,
})
