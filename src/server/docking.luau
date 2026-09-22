-- Which drones are parked on their carrier. A parked drone is held in place on it and does not fight.

local types = require(game:GetService("ReplicatedStorage").Shared.types)

local docked: { [types.EntityId]: boolean } = {}

local function is_docked(entity_id: types.EntityId): boolean
	return docked[entity_id] == true
end

local function set(entity_id: types.EntityId, value: boolean)
	docked[entity_id] = if value then true else nil
end

local function forget(entity_id: types.EntityId)
	docked[entity_id] = nil
end

return table.freeze({
	is_docked = is_docked,
	set = set,
	forget = forget,
})
