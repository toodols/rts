-- What each entity is making or taking in metal and energy this tick, in a second's worth, and whether it is
-- being held back for want of a resource. Generators, converters and builders report it as they work; the
-- infobox reads it from the entity's attributes. It is cleared at the start of every step, so nothing that
-- stopped working is left showing a rate.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type EntityId = types.EntityId

-- Why something is not running at its full rate.
export type Stall = "energy" | "metal" | "storage"

type Flow = {
	-- positive is made, negative is spent
	metal: number,
	energy: number,
	stall: Stall?,
}

local flows: { [EntityId]: Flow } = {}

local function begin_tick()
	table.clear(flows)
end

local function flow_of(entity_id: EntityId): Flow
	local flow = flows[entity_id]
	if flow == nil then
		flow = { metal = 0, energy = 0, stall = nil }
		flows[entity_id] = flow
	end
	return flow
end

-- Adds to what `entity_id` makes (positive) or spends (negative) each second.
local function add(entity_id: EntityId, metal_per_second: number, energy_per_second: number)
	local flow = flow_of(entity_id)
	flow.metal += metal_per_second
	flow.energy += energy_per_second
end

local function stall(entity_id: EntityId, reason: Stall)
	flow_of(entity_id).stall = reason
end

local function get(entity_id: EntityId): Flow?
	return flows[entity_id]
end

return table.freeze({
	begin_tick = begin_tick,
	add = add,
	stall = stall,
	get = get,
})
