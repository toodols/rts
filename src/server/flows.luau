-- What each entity is making or taking in metal and energy this tick, in a second's worth, and whether it is
-- being held back for want of a resource. Generators, converters and builders report it as they work, each under a
-- word or two on where it comes from ("Generating", "Building Grunt"), so the infobox can show the sum and, over it,
-- what makes it up. It reads both from the entity's attributes. It is cleared at the start of every step, so nothing
-- that stopped working is left showing a rate.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

type EntityId = types.EntityId

-- Why something is not running at its full rate.
export type Stall = "energy" | "metal" | "storage"

-- One source of what an entity makes or spends, in a second's worth.
type Source = entity_attrs.FlowSource

export type Flow = {
	-- positive is made, negative is spent
	metal: number,
	energy: number,
	stall: Stall?,
	-- what the totals are made of, in the order each was first added this tick
	sources: { Source },
}

local flows: { [EntityId]: Flow } = {}

local function begin_tick()
	table.clear(flows)
end

local function flow_of(entity_id: EntityId): Flow
	local flow = flows[entity_id]
	if flow == nil then
		flow = { metal = 0, energy = 0, stall = nil, sources = {} }
		flows[entity_id] = flow
	end
	return flow
end

-- Adds to what `entity_id` makes (positive) or spends (negative) each second, from the source `label` names. What
-- comes from one source twice in a tick, like a builder feeding two blueprints of the same thing, is summed under it.
local function add(entity_id: EntityId, label: string, metal_per_second: number, energy_per_second: number)
	local flow = flow_of(entity_id)
	flow.metal += metal_per_second
	flow.energy += energy_per_second
	for _, source in flow.sources do
		if source.label == label then
			source.metal += metal_per_second
			source.energy += energy_per_second
			return
		end
	end
	table.insert(flow.sources, { label = label, metal = metal_per_second, energy = energy_per_second })
end

local function stall(entity_id: EntityId, reason: Stall)
	flow_of(entity_id).stall = reason
end

local function get(entity_id: EntityId): Flow?
	return flows[entity_id]
end

-- Rounds to a tenth, the precision the infobox shows.
local function tenth(value: number): number
	return math.round(value * 10) / 10
end

-- `entity_id`'s sources, to the infobox's precision, leaving out any that come to nothing at it.
local function shown_sources(entity_id: EntityId): { Source }
	local shown: { Source } = {}
	local flow = flows[entity_id]
	if flow ~= nil then
		for _, source in flow.sources do
			local metal = tenth(source.metal)
			local energy = tenth(source.energy)
			if metal ~= 0 or energy ~= 0 then
				table.insert(shown, { label = source.label, metal = metal, energy = energy })
			end
		end
	end
	return shown
end

-- Publishes what `entity` is making or spending this second, in metal and energy, to a tenth (`metal_rate`,
-- `energy_rate`), what is holding it back if anything is (`stalled`), and what that is made of (`flow_sources`); all nil
-- for something that makes and spends nothing.
local function publish(entity: types.Entity, _def: types.EntityDef, write: entity_attrs.Publish)
	local flow = flows[entity.id]
	write("metal_rate", if flow ~= nil then tenth(flow.metal) else nil)
	write("energy_rate", if flow ~= nil then tenth(flow.energy) else nil)
	write("stalled", if flow ~= nil then flow.stall else nil)
	write("flow_sources", entity_attrs.encode_flow_sources(shown_sources(entity.id)))
end

return table.freeze({
	get = get,
	begin_tick = begin_tick,
	add = add,
	stall = stall,
	publish = publish,
})
