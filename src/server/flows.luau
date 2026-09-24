-- What each entity is making or taking in metal and energy this tick, in a second's worth, and whether it is
-- being held back for want of a resource. Generators, converters and builders report it as they work, each under a
-- word or two on where it comes from ("Generating", "Building Grunt"), so the infobox can show the sum and, over it,
-- what makes it up. It reads both from the entity's attributes. It is cleared at the start of every step, so nothing
-- that stopped working is left showing a rate.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

type EntityId = types.EntityId

-- Why something is not running at its full rate.
export type Stall = "energy" | "metal" | "storage"

-- One source of what an entity makes or spends, in a second's worth.
export type Source = {
	label: string,
	metal: number,
	energy: number,
}

type Flow = {
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

-- `entity_id`'s sources as one string for an attribute, "label|metal|energy" for each joined by ";", leaving out any
-- that come to nothing at the infobox's precision. Nil when there are none.
local function encode_sources(entity_id: EntityId): string?
	local flow = flows[entity_id]
	if flow == nil then
		return nil
	end
	local parts = {}
	for _, source in flow.sources do
		local metal = tenth(source.metal)
		local energy = tenth(source.energy)
		if metal ~= 0 or energy ~= 0 then
			table.insert(parts, `{source.label}|{metal}|{energy}`)
		end
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, ";")
end

return table.freeze({
	begin_tick = begin_tick,
	add = add,
	stall = stall,
	get = get,
	encode_sources = encode_sources,
})
