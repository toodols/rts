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
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local state = require(script.Parent.state)

type Entity = types.Entity
type EntityId = types.EntityId

-- BAR's `paralyzeDeclineRate`: `emp` drains by max health over this many seconds
local DECLINE_SECONDS = 40
-- the longest anything that is not a building can be stunned for
local MOBILE_MAX_STUN = 20

-- Everything that has any EMP in it, by id, for it to drain away from.
local charged: { [EntityId]: Entity } = {}

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

-- `target` takes `amount` of EMP from a weapon that stuns for at most `paralyze_time` seconds. Anything wholly
-- resistant, a wreck among them, takes none.
local function add(target: Entity, amount: number, paralyze_time: number)
	if target.max_health <= 0 then
		return
	end
	amount *= 1 - math.clamp(target.def.emp_resistance or 0, 0, 1)
	if amount <= 0 then
		return
	end
	local stun = if target.kind == "building" then paralyze_time else math.min(paralyze_time, MOBILE_MAX_STUN)
	local most = target.max_health * (1 + stun / DECLINE_SECONDS)
	target.emp += math.clamp(amount, 0, math.max(0, most - target.emp))
	if target.emp > 0 then
		charged[target.id] = target
	end
end

-- Drains everything's `emp` by a step's worth.
local function tick(delta: number)
	for id, entity in charged do
		-- what hangs from a transport is out of the world, and keeps what it has until it is set down
		if entity.alive == false or state.carrier_of(id) ~= nil then
			continue
		end
		entity.emp = math.max(0, entity.emp - entity.max_health / DECLINE_SECONDS * delta)
		if entity.emp <= 0 then
			charged[id] = nil
		end
	end
end

local function forget(id: EntityId)
	charged[id] = nil
end

-- Publishes `entity`'s EMP, in whole percent of its max health (`emp`), and while that has it stunned, whole seconds until
-- it is not, rounded up (`stun`); both nil when there is none.
local function publish(entity: Entity, _def: types.EntityDef, write: entity_attrs.Publish)
	write(
		"emp",
		if entity.emp > 0 then math.max(1, math.floor(entity.emp / math.max(entity.max_health, 1) * 100)) else nil
	)
	local stun_left = seconds_left(entity)
	write("stun", if stun_left ~= nil then math.max(1, math.ceil(stun_left)) else nil)
end

return table.freeze({
	seconds_left = seconds_left,
	is_stunned = is_stunned,
	add = add,
	tick = tick,
	publish = publish,
	forget = forget,
})
