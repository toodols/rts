--!strict
-- The way a unit goes on an order a player gives it. The client finds it, for each unit it orders, and sends it with
-- the order (`waypoints`, client/orders.luau); the server searches for nothing and only checks that every leg of what
-- it is sent can be walked (`along`, server/commands.luau), so there is no limit on how many units of a big order find
-- their way. The route stops where what the order is aimed at comes into the unit's reach (order_kinds.reach), and the
-- order walks the rest.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local walls = require(ReplicatedStorage.Shared.walls)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

type EntityDef = types.EntityDef
type Order = types.Order

-- A route longer than this is not sent, and the server hears no longer one (server/commands.luau).
local MAX_WAYPOINTS = 128

-- The waypoints something of `def` at `from` is sent through on an order of `kind` (a launch, with `launch`) to
-- `destination`, `radius` the area an area order covers. None for something that does not walk (`unit_defs.walks`): a
-- building, a lab among them, whose orders are for the units it makes, or an aircraft, which flies straight over
-- everything.
local function waypoints(
	def: EntityDef,
	from: Vector3,
	kind: order_kinds.Command,
	launch: boolean,
	destination: Vector3,
	radius: number?
): { Vector3 }
	if unit_defs.walks(def) == false then
		return {}
	end
	local reach = order_kinds.reach(def, kind, launch) + (radius or 0)
	local found = pathfinder.waypoints_to(def, from, destination, reach, pathfinder.MAX_EXPANSIONS) or {}
	return if #found <= MAX_WAYPOINTS then found else {}
end

-- `order` for something of `def` setting off from `from`, with the way to its spot laid ahead of it as waypoints of its
-- kind's `route_as` (`waypoints`), as the client lays a player's order: what a lab's units are sent on. Just the order
-- for one with no spot, or for something that does not walk.
local function routed(def: EntityDef, from: Vector3, order: Order): { Order }
	local destination = order.position
	if destination == nil then
		return { order }
	end
	local kind = order_kinds.get(order.kind)
	local steps: { Order } = {}
	for _, point in waypoints(def, from, order.kind, order.launch == true, destination, order.radius) do
		table.insert(steps, { kind = kind.route_as, position = point, target_id = nil })
	end
	table.insert(steps, order)
	return steps
end

-- `order` for something of `def`, with the way to it a client sent, `route` (points on the map, no more than
-- MAX_WAYPOINTS of them, as the server hears it), laid ahead of it: waypoints of the order's kind's `route_as`, moves,
-- or for a fight, fights, so it fights its way along all of it. The way is only taken if
-- nothing blocks any leg of it (`pathfinder.has_open_line`), and the last leg too for an order that `walks_up_to` its
-- spot, unless that is inside a building, which it walks up to the edge of (shared/walls.luau); otherwise the order is
-- given without it. The leg from where the unit stands is not checked, since it has
-- moved on since the client saw it.
local function along(def: EntityDef, order: Order, route: { Vector3 }?): { Order }
	if route == nil or #route == 0 or unit_defs.walks(def) == false then
		return { order }
	end
	local kind = order_kinds.get(order.kind)
	local steps: { Order } = {}
	local previous: Vector3? = nil
	for _, point in route do
		local at = surface.position(def, point.X, point.Z)
		if previous ~= nil and pathfinder.has_open_line(def, previous, at) == false then
			return { order }
		end
		table.insert(steps, { kind = kind.route_as, position = at, target_id = nil })
		previous = at
	end
	if
		kind.walks_up_to
		and previous ~= nil
		and order.position ~= nil
		and walls.blocked_at(order.position.X, order.position.Z) == false
		and pathfinder.has_open_line(def, previous, order.position) == false
	then
		return { order }
	end
	table.insert(steps, order)
	return steps
end

return table.freeze({
	MAX_WAYPOINTS = MAX_WAYPOINTS,
	waypoints = waypoints,
	routed = routed,
	along = along,
})
