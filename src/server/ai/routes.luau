--!strict
-- The ways a brain sends its units: how dangerous a way is (`route_danger`, `chain_danger`), and the routes round what
-- is in the way, of which each brain has only its share (server/paths.luau) in a thought (`waypoints`, `orders_to`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local surface = require(ReplicatedStorage.Shared.surface)
local geometry = require(ReplicatedStorage.Shared.geometry)

local paths = require(ServerScriptService.Server.paths)

local danger_field = require(script.Parent.danger_field)
local brains = require(script.Parent.brains)

type Entity = types.Entity
type Order = types.Order
type OrderKind = types.OrderKind
type Brain = brains.Brain

-- What the brains ask the routes of: six a step for each brain that thinks in it, each settling no more than 4000
-- cells.
local ASKER: paths.Asker = table.freeze({ name = "ai", share = 6, max_expansions = 4000 })

-- The most danger on the way from `from` to `to`, leaving out the cell it sets out from, so that one standing
-- somewhere the danger just touches can still be sent away from it.
local function route_danger(brain: Brain, from: Vector3, to: Vector3): number
	local offset = geometry.flatten(to - from)
	if offset.Magnitude <= danger_field.CELL_STUDS then
		return danger_field.at(brain.field, to)
	end
	return danger_field.peak_along(brain.field, from + offset.Unit * danger_field.CELL_STUDS, to)
end

-- The most danger on the way `unit` would go through the moves of `chain` and on to `goal`.
local function chain_danger(brain: Brain, unit: Entity, chain: { Order }, goal: Vector3): number
	local from = unit.position
	local peak = 0
	for _, order in chain do
		local position = order.position
		if order.kind == "move" and position ~= nil then
			peak = math.max(peak, route_danger(brain, from, position))
			from = position
		end
	end
	return math.max(peak, route_danger(brain, from, goal))
end

-- The way for `unit` of `brain`'s to within `reach` of `goal`, as move orders to go before the order that takes it
-- there, or nil if it needs a route and the brain has none left to have.
local function waypoints(brain: Brain, unit: Entity, goal: Vector3, reach: number): { Order }?
	local def = unit.def
	local points = paths.waypoints(ASKER, brain.team, def, unit.position, goal, reach)
	if points == nil then
		return nil
	end
	local chain: { Order } = {}
	for _, point in points do
		table.insert(chain, { kind = "move", position = surface.position(def, point.X, point.Z) })
	end
	return chain
end

-- Orders of `kind` that take `unit` of `brain`'s to `goal`, by a route if it needs one (straight at it if the route got
-- nowhere), or nil when it needs one and the brain has none left to have.
local function orders_to(brain: Brain, unit: Entity, goal: Vector3, kind: OrderKind): { Order }?
	local def = unit.def
	local route = paths.route(ASKER, brain.team, def, unit.position, goal, kind)
	if route == nil then
		return nil
	end
	return paths.or_straight(route, def, goal, kind)
end

return table.freeze({
	route_danger = route_danger,
	chain_danger = chain_danger,
	waypoints = waypoints,
	orders_to = orders_to,
})
