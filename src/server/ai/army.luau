--!strict
-- The army. It waits at its rally point until it is worth the profile's wave_base plus its wave_income_seconds of the
-- metal income (grown by its wave_growth, see `wave_needed`), and then sets out, what waited at home going as a wave,
-- at something its attack_rule says it beats (targets.luau). Out there the wave pulls back to regroup for its
-- regroup_seconds once its retreat_rule says it is outmatched (`OUTMATCHED`), or once it has lost most of what set out.
-- An enemy that has come near home or an extractor is seen off first, by as much as it takes (defence.luau) or, with
-- no defend_share, by the whole army. With the profile's strike_groups, a wave that sets out with more than its target
-- takes sends what it does not need at another target as a strike (groups.luau's `split_wave`).
--
-- What the army is doing is its brain's `army` record: a wave out, the whole army seeing off an intruder, or neither,
-- when it gathers at its rally point. Which units are out with the wave is their assignments' to say.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

local state = require(ServerScriptService.Server.state)

local danger_field = require(script.Parent.danger_field)
local brains = require(script.Parent.brains)
local assignments = require(script.Parent.assignments)
local censuses = require(script.Parent.census)
local squads = require(script.Parent.squads)
local targets = require(script.Parent.targets)
local defence = require(script.Parent.defence)
local predictions = require(script.Parent.predictions)
local sorties = require(script.Parent.sorties)
local groups = require(script.Parent.groups)

type Entity = types.Entity
type Brain = brains.Brain
type Census = censuses.Census
type Economy = censuses.Economy
type WaveEnd = sorties.WaveEnd
type Rule = ai_profiles.Rule

-- What the army is doing: gathering at its rally point, out with a wave, or seeing off an intruder with everything.
export type Mode = "gather" | "attack" | "defend"

-- By the retreat_rule "sim", the fight of a wave out is predicted again every this many seconds.
local SIM_CHECK_INTERVAL = 3

-- Whether the wave out, `wave` worth `worth` with its middle at `middle`, is outmatched where it stands, by each
-- retreat_rule: the danger there is over its retreat_ratio of what it is worth, or the fight it is in is predicted to
-- go against it by more than its sim_retreat_margin (asked again only every SIM_CHECK_INTERVAL).
local OUTMATCHED: { [Rule]: (Brain, Census, { Entity }, Vector3, number) -> boolean } = table.freeze({
	danger = function(brain: Brain, _census: Census, _wave: { Entity }, middle: Vector3, worth: number): boolean
		return danger_field.at(brain.field, middle) > worth * brain.profile.retreat_ratio
	end,
	sim = function(brain: Brain, census: Census, wave: { Entity }, middle: Vector3, _worth: number): boolean
		local now = brains.now()
		if now < brain.army.next_sim_check then
			return false
		end
		local margin = predictions.predict(brain, wave, predictions.enemies_near(census, middle)).margin
		if margin < brain.profile.sim_retreat_margin then
			return true
		end
		brain.army.next_sim_check = now + SIM_CHECK_INTERVAL
		return false
	end,
})

-- What the army is doing.
local function mode_of(brain: Brain): Mode
	local army = brain.army
	return if army.wave ~= nil then "attack" elseif army.defending ~= nil then "defend" else "gather"
end

-- What the army has to be worth to set out: the profile's wave_base and wave_income_seconds of its metal income, grown
-- by its wave_growth for every wave it has already sent, but never past its wave_cap_seconds of its whole income (nor
-- below wave_base), so that each wave is bigger than the last and still goes once the income can pay for it.
local function wave_needed(brain: Brain, economy: Economy): number
	local profile = brain.profile
	local needed = profile.wave_base + economy.metal_income * profile.wave_income_seconds
	if profile.wave_growth > 0 then
		needed *= 1 + profile.wave_growth * brain.army.waves_sent
	end
	local cap_seconds = profile.wave_cap_seconds
	if cap_seconds ~= nil then
		local cap = (economy.metal_income + economy.converted_metal) * cap_seconds
		needed = math.min(needed, math.max(profile.wave_base, cap))
	end
	return needed
end

-- Ends the wave that is out, `how`, and lets what is left of it go back to the army.
local function end_wave(brain: Brain, how: WaveEnd)
	assignments.release_all(brain, "wave", true)
	brain.army.wave = nil
	sorties.ended(brain, how)
end

local function run_army(brain: Brain, census: Census, economy: Economy)
	local profile = brain.profile
	local record = brain.army
	local now = brains.now()
	local army: { Entity } = {}
	for _, unit in census.army do
		if assignments.with_army(brain, unit) then
			table.insert(army, unit)
		end
	end
	if #army == 0 then
		if record.wave ~= nil then
			end_wave(brain, "lost")
		end
		record.defending = nil
		assignments.release_all(brain, "defend", false)
		return
	end

	local intruder = targets.nearest_intruder(brain, census)
	-- with the profile's defend_share, only as much as it takes goes, and the rest carry on with what they were doing
	local share = profile.defend_share
	if intruder ~= nil and share ~= nil then
		local rest = defence.defend_in_proportion(brain, census, army, intruder, share)
		if rest ~= nil then
			army = rest
			intruder = nil
		end
	elseif assignments.any(brain, "defend") then
		defence.recall(brain)
	end
	if intruder ~= nil then
		-- the whole army goes, those already sent keeping on
		assignments.release_all(brain, "defend", false)
		if record.wave ~= nil then
			end_wave(brain, "defend")
		end
		record.defending = intruder.id
		squads.send_all(brain, army, intruder.position, "fight", 0)
		return
	end
	record.defending = nil

	-- what is out is the wave that set out; what the labs have made since waits at home for the next
	local home: { Entity } = army
	local wave_out = record.wave
	if wave_out ~= nil then
		local wave: { Entity } = {}
		home = {}
		for _, unit in army do
			table.insert(if assignments.job_of(brain, unit.id) == "wave" then wave else home, unit)
		end
		local worth = squads.worth_of(wave)
		local middle = squads.centroid(wave)
		local ended: WaveEnd? = nil
		if #wave == 0 then
			ended = "lost"
		elseif worth < wave_out.worth * profile.wave_broken_share then
			ended = "broken"
		elseif OUTMATCHED[profile.retreat_rule](brain, census, wave, middle, worth) then
			ended = "outmatched"
		else
			local target = if wave_out.target ~= nil then state.get(wave_out.target) else nil
			if target == nil or target.team == brain.team then
				target = targets.choose_target(brain, census, wave, middle, worth)
				wave_out.target = if target ~= nil then target.id else nil
			end
			if target ~= nil then
				squads.send_all(brain, wave, target.position, "fight", 0)
			else
				ended = "won"
			end
		end
		if ended == nil then
			squads.send_all(brain, home, squads.rally_point(brain), "move", squads.RALLY_SLACK)
			return
		end
		end_wave(brain, ended)
		-- beaten, it regroups before it goes again
		if ended ~= "won" then
			record.next_attack_at = now + profile.regroup_seconds
		end
		home = army
	end

	-- gathering: waiting at the rally point until it is worth enough to go
	squads.send_all(brain, home, squads.rally_point(brain), "move", squads.RALLY_SLACK)
	local worth = squads.worth_of(home)
	local needed = wave_needed(brain, economy)
	if now >= record.next_attack_at and worth >= needed then
		local from = squads.centroid(home)
		local target = targets.choose_target(brain, census, home, from, worth)
		if target ~= nil then
			home = groups.split_wave(brain, census, home, target, from)
			worth = squads.worth_of(home)
			record.wave = { worth = worth, target = target.id }
			record.waves_sent += 1
			for _, unit in home do
				assignments.assign(brain, unit.id, { job = "wave" })
			end
			sorties.sent(
				brain,
				"wave",
				{ at = now - brain.started, units = #home, worth = worth, needed = needed, target = target.def_name }
			)
		end
	end
end

return table.freeze({
	mode_of = mode_of,
	wave_needed = wave_needed,
	run_army = run_army,
})
