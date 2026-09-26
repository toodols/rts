--!strict
-- Who has a unit's controls this moment. Its orders do, as a rule; a developer piloting it (server/pilots.luau) takes
-- them over; and nobody has them while EMP has it stunned (server/emp.luau), whatever it was told or its pilot steers.
-- What is dead, unfinished, a wreck or a reclaimable is inert: nothing controls it. A drone parked on its carrier is
-- docked (server/drones.luau): its carrier has it, and it does nothing of its own until it is sent out. Everything that
-- moves a unit, fires its weapons or has it make anything asks here, and nowhere else, whether it may.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local pilots = require(script.Parent.pilots)
local emp = require(script.Parent.emp)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type EntityId = types.EntityId

export type Mode = "inert" | "docked" | "stunned" | "piloted" | "orders"

-- The drones parked on their carriers.
local docked: { [EntityId]: true } = {}

local function mode_of(entity: Entity): Mode
	if entity.alive == false or entity.state ~= "active" or unit_defs.is_remains(entity.def) then
		return "inert"
	end
	if docked[entity.id] ~= nil then
		return "docked"
	end
	if emp.is_stunned(entity) then
		return "stunned"
	end
	if pilots.get(entity.id) ~= nil then
		return "piloted"
	end
	return "orders"
end

-- Whether `entity` can do anything at all this moment, whoever is in control of it.
local function can_act(entity: Entity): boolean
	local mode = mode_of(entity)
	return mode == "orders" or mode == "piloted"
end

-- The pilot in control of `entity`, if one is.
local function pilot_of(entity: Entity): pilots.Pilot?
	if mode_of(entity) ~= "piloted" then
		return nil
	end
	return pilots.get(entity.id)
end

-- Parks the drone `entity_id` on its carrier (`dock`), or sends it out again.
local function dock(entity_id: EntityId, parked: boolean)
	if parked then
		docked[entity_id] = true
	else
		docked[entity_id] = nil
	end
end

local function forget(entity_id: EntityId)
	docked[entity_id] = nil
end

snapshot.keep("control", function()
	return { docked = docked }
end, function(saved)
	docked = saved.docked
end)

return table.freeze({
	mode_of = mode_of,
	dock = dock,
	forget = forget,
	can_act = can_act,
	pilot_of = pilot_of,
})
