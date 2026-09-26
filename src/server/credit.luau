--!strict
-- What a unit is credited with for the damage it deals and what it kills, as BAR (the Spring engine, CUnit::DoDamage)
-- credits it: damage earns a tenth of the share of the target's health it took, and a kill a tenth more, both scaled by
-- the target's power over the attacker's. So killing something worth as much as the killer earns 0.2, and killing
-- something worth a quarter of it 0.05. Only damage an enemy takes counts, and only up to its last hit point; a
-- blueprint's damage counts but its death is no kill. The team's tally for the end screen (`match_stats`) counts the
-- same.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local teams = require(ReplicatedStorage.Shared.teams)

local alliances = require(script.Parent.alliances)
local match_stats = require(script.Parent.match_stats)

type Entity = types.Entity

local EXPERIENCE_SCALE = 0.1

-- Whether what `attacker` does to `target` is credited to it: it is still standing, and `target` is an enemy's, not
-- neutral, as remains are.
local function earns(attacker: Entity, target: Entity): boolean
	return attacker.alive
		and attacker.id ~= target.id
		and target.team ~= teams.NEUTRAL
		and alliances.are_allied(attacker.team, target.team) == false
end

-- How `target`'s power compares with `attacker`'s, which scales what either earns.
local function ratio_of(attacker: Entity, target: Entity): number
	return unit_defs.power(target.def) / math.max(unit_defs.power(attacker.def), 1)
end

-- `attacker` has taken `dealt` of `target`'s health.
local function damage(attacker: Entity, target: Entity, dealt: number)
	local def = target.def
	local power = unit_defs.power(def)
	-- a blueprint's health grows as it is built, so what is taken off it is weighed against what it will have
	local share = dealt / math.max(target.max_health, unit_defs.max_health(def), 1)
	attacker.damage_dealt += dealt
	attacker.score_dealt += power * share
	attacker.experience += EXPERIENCE_SCALE * ratio_of(attacker, target) * share
	match_stats.dealt(attacker.team, dealt, power * share)
end

-- `attacker` has killed `target`, which counts only if it was finished.
local function kill(attacker: Entity, target: Entity)
	if target.state ~= "active" then
		return
	end
	attacker.kills += 1
	attacker.experience += EXPERIENCE_SCALE * ratio_of(attacker, target)
	match_stats.killed(attacker.team)
end

return table.freeze({
	earns = earns,
	damage = damage,
	kill = kill,
})
