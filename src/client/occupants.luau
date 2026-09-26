--!strict
-- The map as the placement rules see it (shared/placement_rules) from what the client can see: the entity models. There
-- is no index to search, so everything is looked at, and nothing counts as up in the air. The server judges again
-- before it creates anything, so a disagreement costs a rejected order, not an exploit.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local placement_rules = require(ReplicatedStorage.Shared.placement_rules)
local order_path = require(ReplicatedStorage.Shared.order_path)

local world = require(ReplicatedStorage.Client.world)

type EntityId = types.EntityId
type Occupants = placement_rules.Occupants<Model>

local function facing_of(model: Model): number
	return select(2, model:GetPivot():ToOrientation())
end
local function never(_: Model): boolean
	return false
end
-- what the builder clears off a footprint when it gets there: wrecks, reclaimables, and your own units that can move
local function clearable(model: Model): boolean
	local kind: types.EntityKind? = entity_attrs.kind(model)
	local state: types.EntityState? = entity_attrs.state(model)
	local def = world.def_of(model)
	if kind == nil or state == nil or def == nil then
		return false
	end
	return placement_rules.clearable(kind, state, def, world.is_mine(model))
end

-- The models `counts` says yes of, as the placement rules see them.
local function only(counts: (Model) -> boolean): Occupants
	local occupants: Occupants = {
		each_near = function(_x: number, _z: number, _radius: number, visit: (Model) -> ())
			for _, model in world.all() do
				if counts(model) then
					visit(model)
				end
			end
		end,
		kind = entity_attrs.kind,
		def = world.def_of,
		position = world.position_of,
		facing = facing_of,
		airborne = never,
		clearable = clearable,
	}
	return table.freeze(occupants)
end

-- Every model.
local ALL = only(function(_: Model): boolean
	return true
end)

-- Where `builder_id` already has something spot-bound queued to be built, as the server published its queue: only its
-- own queue takes a spot from it, as on the server.
local function queued_spots(builder_id: EntityId?): { Vector3 }
	local found: { Vector3 } = {}
	local builder = if builder_id ~= nil then world.get(builder_id) else nil
	local path = if builder ~= nil then entity_attrs.text(builder, "path") else nil
	if path == nil then
		return found
	end
	for _, step in order_path.decode(path) do
		local queued = if step.kind == "build" and step.def_name ~= nil then unit_defs.defs[step.def_name] else nil
		if queued ~= nil and queued.spot ~= nil then
			table.insert(found, Vector3.new(step.x, 0, step.z))
		end
	end
	return found
end

return table.freeze({
	ALL = ALL,
	only = only,
	queued_spots = queued_spots,
})
