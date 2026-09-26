-- Shields: a sphere round what carries it that takes enemy harm in its `power` instead of what it covers. A plasma
-- deflector's (`Shield.blocks` "plasma") swallows any plasma shell of an enemy that flies into it: the shell goes off
-- harmlessly at the edge and the shield's power drops by the damage it would have done, however much that is; rockets
-- and beams pass straight through it. One that blocks "all" takes every weapon's harm that comes to what is inside it,
-- beams, shells and blasts alike, out of its power first, and only what its power cannot cover gets through. A shield
-- with no power left lets everything through until it has built some back up, which it does at a set rate for a set
-- price in energy, and holds off whatever cannot be paid for. A shot that was fired from inside a shield is not
-- stopped by it, and neither is anything of the shield's own side.
--
-- A switched shield (`Shield.upkeep`), the commander's, is off until it is switched on, and costs its upkeep every
-- second it is up, more while it moves than while it stands: when that cannot be paid, or its power runs out, it goes
-- off. It only grows back while off.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local flows = require(script.Parent.flows)
local alliances = require(script.Parent.alliances)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type EntityId = types.EntityId

-- Faster than this, in studs a second, something is moving, and pays a switched shield's moving upkeep.
local MOVING_SPEED = 0.1

-- The power each shield has left, by the id of what carries it.
local power: { [EntityId]: number } = {}
-- The switched shields that are switched on.
local switched_on: { [EntityId]: boolean } = {}
-- The shields that are up this tick: finished, alive, and switched on if they are switched.
local standing: { Entity } = {}

-- The power the shield of `entity` has left: what it starts with until it has been up a step; nothing for what has no
-- shield.
local function power_of(entity: Entity): number
	local shield = entity.def.shield
	if shield == nil then
		return 0
	end
	return power[entity.id] or shield.starting_power
end

-- Whether `entity`'s shield is up: it has one, it is finished, and it is switched on if it is switched.
local function is_up(entity: Entity): boolean
	local shield = entity.def.shield
	if shield == nil or entity.state ~= "active" then
		return false
	end
	return shield.upkeep == nil or switched_on[entity.id] == true
end

-- Switches `entity`'s switched shield on, or off if it is on. One with no power left stays off.
local function toggle(entity: Entity)
	local shield = entity.def.shield
	if shield == nil or shield.upkeep == nil then
		return
	end
	if switched_on[entity.id] then
		switched_on[entity.id] = nil
	elseif power_of(entity) > 0 then
		switched_on[entity.id] = true
	end
end

-- Regrows every shield, and spends the energy that costs, and every switched shield's upkeep. It is run once a tick.
local function tick(delta: number)
	table.clear(standing)
	for _, entity in state.all() do
		if entity.alive == false or entity.state ~= "active" then
			continue
		end
		local shield = entity.def.shield
		if shield == nil then
			continue
		end
		local held = power_of(entity)

		local upkeep = shield.upkeep
		if upkeep ~= nil and switched_on[entity.id] then
			local moving = geometry.flatten(entity.velocity).Magnitude > MOVING_SPEED
			local price = if moving then upkeep.moving else upkeep.standing
			-- aboard a transport, out of power or out of energy, it goes off
			if
				held > 0
				and state.carrier_of(entity.id) == nil
				and economy.spend(entity.team, 0, price * delta, entity.id)
			then
				flows.add(entity.id, "Shield", 0, -price)
				table.insert(standing, entity)
			else
				switched_on[entity.id] = nil
			end
		elseif upkeep == nil then
			table.insert(standing, entity)
		end

		-- a switched shield only regrows while it is off
		if held < shield.power and (upkeep == nil or switched_on[entity.id] == nil) then
			-- it only regrows if the energy for it can be paid
			local price = shield.regen_energy * delta
			if economy.spend(entity.team, 0, price, entity.id) then
				held = math.min(shield.power, held + shield.regen * delta)
				if shield.regen_energy > 0 then
					flows.add(entity.id, "Shield regen", 0, -shield.regen_energy)
				end
			end
		end
		power[entity.id] = held
	end
end

-- Every shield that `at` is inside, whoever's it is. A shot fired from there is not stopped by them.
local function covering(at: Vector3): { [EntityId]: boolean }
	local result = {}
	for _, entity in standing do
		local shield = entity.def.shield
		if shield ~= nil and (at - entity.position).Magnitude <= shield.radius then
			result[entity.id] = true
		end
	end
	return result
end

-- The shield of `entity`, down to `held` power, takes up to `damage` of harm, and goes off if it is switched and has
-- none left. What it could not take is left over.
local function take(entity: Entity, held: number, damage: number): number
	local taken = math.min(held, damage)
	power[entity.id] = held - taken
	if held - taken <= 0 then
		switched_on[entity.id] = nil
	end
	return damage - taken
end

-- The first shield that is up with power left, stops what `blocks` says, and is an enemy of `team`'s (and so not one
-- it fired from inside: `exempt`) round `at`, if any, with its power.
local function enemy_shield_round(
	at: Vector3,
	blocks: "plasma" | "all",
	team: types.TeamId,
	exempt: { [EntityId]: boolean }
): (Entity?, number)
	for _, entity in standing do
		if entity.alive == false or exempt[entity.id] or alliances.are_allied(entity.team, team) then
			continue
		end
		local shield = entity.def.shield
		local held = power[entity.id]
		if shield == nil or shield.blocks ~= blocks or held == nil or held <= 0 then
			continue
		end
		if (at - entity.position).Magnitude <= shield.radius then
			return entity, held
		end
	end
	return nil, 0
end

-- Whether a plasma shell of `team` at `at` runs into a plasma deflector that stops it, leaving out the shields it was
-- fired from inside (`exempt`). If one does, it takes `damage` off the shield's power, all of it or down to nothing.
local function absorb(at: Vector3, damage: number, team: types.TeamId, exempt: { [EntityId]: boolean }): boolean
	local entity, held = enemy_shield_round(at, "plasma", team, exempt)
	if entity == nil then
		return false
	end
	take(entity, held, math.min(held, damage))
	return true
end

-- How much of `damage` from a weapon of `team`'s gets through to `target`, once any enemy shield round it that blocks
-- everything, other than those it was fired from inside (`exempt`), has taken what it can.
local function shelter(target: Entity, damage: number, team: types.TeamId, exempt: { [EntityId]: boolean }): number
	local entity, held = enemy_shield_round(target.position, "all", team, exempt)
	if entity == nil then
		return damage
	end
	return take(entity, held, damage)
end

-- Publishes a shield's power, to the nearest whole (`shield_power`), and its most (`shield_max`).
local function publish(entity: Entity, def: types.EntityDef, write: entity_attrs.Publish)
	local shield = def.shield
	if shield == nil then
		return
	end
	write("shield_power", math.round(power_of(entity)))
	write("shield_max", shield.power)
end

local function forget(id: EntityId)
	power[id] = nil
	switched_on[id] = nil
end

snapshot.keep("shields", function()
	return { power = power, switched_on = switched_on, standing = standing }
end, function(saved)
	power = saved.power
	switched_on = saved.switched_on
	standing = saved.standing
end)

return table.freeze({
	forget = forget,
	tick = tick,
	toggle = toggle,
	is_up = is_up,
	covering = covering,
	absorb = absorb,
	shelter = shelter,
	publish = publish,
	power_of = power_of,
})
