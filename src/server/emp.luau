-- EMP, as BAR has it (the Recoil engine's paralyze damage, with BAR's modrules and its paralyze gadgets).
--
-- An EMP weapon (`Weapon.paralyze_time`) deals its damage into what it reaches's `emp` instead of its health, less
-- the share its `emp_resistance` shrugs off (BAR's `paralyzemultiplier`, luarules/gadgets/unit_paralyze_damage_multiplier.lua).
-- Once `emp` is at least its max health it is stunned (`paralyzeOnMaxHealth`): it cannot move, shoot, build or make
-- anything, and its weapons stop reloading. `emp` drains away all the time, hit or not, a fortieth of its max health a
-- second (`paralyzeDeclineRate` 40), so the stun wears off as `emp` falls back under its max health.
--
-- One hit can only fill `emp` so far over the max health that the stun lasts the weapon's `paralyze_time` from then,
-- and no longer: max health times 1 + paralyze_time / 40 (Unit.cpp, CUnit::ApplyDamage). Something that moves is
-- never stunned for more than 20 seconds by anything (luarules/gadgets/unit_paralyze_damage_limit.lua).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)

type Entity = types.Entity

-- BAR's `paralyzeDeclineRate`: `emp` drains by max health over this many seconds
local DECLINE_SECONDS = 40
-- the longest anything that is not a building can be stunned for
local MOBILE_MAX_STUN = 20

local function is_stunned(entity: Entity): boolean
	return entity.emp > 0 and entity.emp >= entity.max_health
end

-- How many seconds `entity` stays stunned if nothing adds to its `emp`; nil when it is not stunned.
local function seconds_left(entity: Entity): number?
	if is_stunned(entity) == false then
		return nil
	end
	return (entity.emp - entity.max_health) / (entity.max_health / DECLINE_SECONDS)
end

-- `target` takes `amount` of EMP from a weapon that stuns for at most `paralyze_time` seconds. A wreck, a reclaimable
-- and anything wholly resistant take none.
local function add(target: Entity, amount: number, paralyze_time: number)
	if target.kind == "wreck" or target.kind == "reclaimable" or target.max_health <= 0 then
		return
	end
	amount *= 1 - math.clamp(unit_defs.of(target).emp_resistance or 0, 0, 1)
	if amount <= 0 then
		return
	end
	local stun = if target.kind == "building" then paralyze_time else math.min(paralyze_time, MOBILE_MAX_STUN)
	local most = target.max_health * (1 + stun / DECLINE_SECONDS)
	target.emp += math.clamp(amount, 0, math.max(0, most - target.emp))
end

-- Drains everything's `emp` by a step's worth.
local function tick(delta: number)
	for _, entity in state.all() do
		if entity.alive == false or entity.emp <= 0 then
			continue
		end
		entity.emp = math.max(0, entity.emp - entity.max_health / DECLINE_SECONDS * delta)
	end
end

return table.freeze({
	is_stunned = is_stunned,
	seconds_left = seconds_left,
	add = add,
	tick = tick,
})
