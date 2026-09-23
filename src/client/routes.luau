-- The way each unit goes when it is given an order, worked out here and sent with the order. The server searches for
-- nothing: it only checks that every leg of what it is sent can be walked (`commands.with_route`), so there is no
-- limit on how many units of a big order find their way. The route stops where what the order is aimed at comes into
-- the unit's reach (`pathfinder.waypoints_to`), and the order walks the rest.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

local world = require(ReplicatedStorage.Client.world)

type EntityId = types.EntityId

-- The most cells one unit's search may settle, the same as the server once allowed it.
local MAX_EXPANSIONS = 8000

local function def_of(id: EntityId): types.EntityDef?
	local model = world.get(id)
	local def_name = if model ~= nil then model:GetAttribute "def_name" else nil
	return if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
end

-- Where a unit starts out on an order: where it stands, or, for one added to the back of its queue, where the last
-- order already in it leaves it, as the server published it.
local function start_of(id: EntityId, after_queue: boolean): Vector3?
	local model = world.get(id)
	if model == nil then
		return nil
	end
	if after_queue then
		local path = model:GetAttribute "path"
		if typeof(path) == "string" and path ~= "" then
			local steps = string.split(path, ";")
			local fields = string.split(steps[#steps], ",")
			local x, z = tonumber(fields[2]), tonumber(fields[3])
			if x ~= nil and z ~= nil then
				return Vector3.new(x, 0, z)
			end
		end
	end
	return world.position_of(model)
end

-- The waypoints unit `id` goes through from `from` on its way to an order of `kind` at `destination`, `radius` the
-- area an area order covers. None for something that cannot walk: a lab, whose orders are for the units it makes, a
-- building, or an aircraft, which flies straight over everything.
local function waypoints(id: EntityId, from: Vector3, kind: string, destination: Vector3, radius: number?): { Vector3 }
	local def = def_of(id)
	if def == nil or def.max_speed == nil or def.air ~= nil or unit_defs.is_factory(def) then
		return {}
	end
	local reach = unit_defs.order_reach(def, kind) + (radius or 0)
	return pathfinder.waypoints_to(def, from, destination, reach, MAX_EXPANSIONS)
end

-- The waypoints for each of `ids`, in the same order, given an order of `kind` to `destination_of(index)`.
local function for_units(
	ids: { EntityId },
	kind: string,
	destination_of: (number) -> Vector3?,
	radius: number?,
	queue: boolean,
	front: boolean
): { { Vector3 } }
	local result = table.create(#ids)
	for index, id in ids do
		local destination = destination_of(index)
		local from = start_of(id, queue and front == false)
		if destination == nil or from == nil then
			result[index] = {}
		else
			result[index] = waypoints(id, from, kind, destination, radius)
		end
	end
	return result
end

return table.freeze({
	start_of = start_of,
	waypoints = waypoints,
	for_units = for_units,
})
