-- Plasma deflectors. A shield is a sphere around its building that swallows any plasma shell of an enemy that
-- flies into it: the shell goes off harmlessly at the edge and the shield's power drops by the damage it would
-- have done. A shield with no power left lets everything through until it has built some back up, which it does
-- at a set rate for a set price in energy, and holds off whatever cannot be paid for. A shell that was fired
-- from inside a shield is not stopped by it, and neither is anything of the shield's own side. Rockets and
-- beams are not plasma and pass straight through.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local flows = require(script.Parent.flows)
local alliances = require(script.Parent.alliances)

type Entity = types.Entity
type EntityId = types.EntityId

-- The power each shield has left, by the id of its building.
local power: { [EntityId]: number } = {}
-- The shields that are up this tick: finished, alive and standing.
local standing: { Entity } = {}

-- Regrows every shield, and spends the energy that costs. It is run once a tick.
local function tick(delta: number)
	table.clear(standing)
	local present: { [EntityId]: boolean } = {}
	for _, entity in state.all() do
		if entity.alive == false or entity.state ~= "active" or entity.kind ~= "building" then
			continue
		end
		local shield = unit_defs.of(entity).shield
		if shield == nil then
			continue
		end
		present[entity.id] = true
		table.insert(standing, entity)

		local held = power[entity.id]
		if held == nil then
			held = shield.starting_power
		end
		if held < shield.power then
			-- it only regrows if the energy for it can be paid
			local price = shield.regen_energy * delta
			if economy.try_spend(entity.team, 0, price) then
				held = math.min(shield.power, held + shield.regen * delta)
				flows.add(entity.id, "Shield regen", 0, -shield.regen_energy)
			else
				flows.stall(entity.id, "energy")
			end
		end
		power[entity.id] = held
	end
	for id in power do
		if present[id] == nil then
			power[id] = nil
		end
	end
end

-- Every shield that `at` is inside, whoever's it is. A shell fired from there is not stopped by them.
local function covering(at: Vector3): { [EntityId]: boolean }
	local result = {}
	for _, entity in standing do
		local shield = unit_defs.of(entity).shield
		if shield ~= nil and (at - entity.position).Magnitude <= shield.radius then
			result[entity.id] = true
		end
	end
	return result
end

-- Whether a plasma shell of `team` at `at` runs into a shield that stops it. If one does, it takes `damage` off the
-- shield's power.
local function absorb(at: Vector3, damage: number, team: types.TeamId, exempt: { [EntityId]: boolean }): boolean
	for _, entity in standing do
		if entity.alive == false or exempt[entity.id] or alliances.are_allied(entity.team, team) then
			continue
		end
		local shield = unit_defs.of(entity).shield
		local held = power[entity.id]
		if shield == nil or held == nil or held <= 0 then
			continue
		end
		if (at - entity.position).Magnitude <= shield.radius then
			power[entity.id] = math.max(0, held - damage)
			return true
		end
	end
	return false
end

-- How much power a shield has left, and its most, for showing; nil for something with no shield.
local function level_of(entity: Entity): (number?, number?)
	local shield = unit_defs.of(entity).shield
	if shield == nil then
		return nil, nil
	end
	local held = power[entity.id]
	if held == nil then
		held = shield.starting_power
	end
	return held, shield.power
end

return table.freeze({
	tick = tick,
	covering = covering,
	absorb = absorb,
	level_of = level_of,
})
