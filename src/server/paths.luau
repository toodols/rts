--!strict
-- The routes the game's own players ask the pathfinder for: the AI's brains, the scavengers, a campaign mission's waves
-- and the like. A straight run is nearly free (`pathfinder.has_straight_path`), but a route round what is in the way
-- costs anything from a millisecond to a good deal more, so each asker says what share of routes it may have every
-- step (`Asker`), and past it is refused, to ask again later; the step starts every share over (`begin_step`). A route
-- is asked for, and given as the orders that follow it, by `route` (the way there) and `waypoints` (the way to within
-- reach of somewhere).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local surface = require(ReplicatedStorage.Shared.surface)
local snapshot = require(script.Parent.snapshot)

type Order = types.Order
type OrderKind = types.OrderKind
type EntityDef = types.EntityDef

-- Something that asks for routes: its name, how many routes it may have in a step (each of its parts, if it has
-- several, as the AI has a brain for each team), and how many cells a route of its may settle.
export type Asker = {
	name: string,
	share: number,
	max_expansions: number,
}

-- The way somewhere, as orders of the kind asked for, whether it gets all the way there, and whether it took a search
-- (and so one of the asker's routes) or is a straight run.
export type Route = {
	orders: { Order },
	complete: boolean,
	searched: boolean,
}

-- How many routes each asker (and each part of one) has had this step.
local spent: { [string]: number } = {}

local function begin_step(_delta: number)
	table.clear(spent)
end

-- Asks for a route for `asker`, and its `part` if it has several: whether it may have one now. A route granted counts
-- against its share, whether or not the search then gets anywhere.
local function permit(asker: Asker, part: number?): () -> boolean
	return function(): boolean
		local key = if part ~= nil then `{asker.name} {part}` else asker.name
		local used = spent[key] or 0
		if used >= asker.share then
			return false
		end
		spent[key] = used + 1
		return true
	end
end

-- The way `def` goes from `from` to `to` (`pathfinder.plan`), as orders of `kind`, for `asker`'s `part`: straight
-- there when it can go straight, which costs nothing of its share, and otherwise by a route round what is in the way,
-- which does; nil when it needs one and has none left this step. A route that got nowhere has no orders.
local function route(asker: Asker, part: number?, def: EntityDef, from: Vector3, to: Vector3, kind: OrderKind): Route?
	local path, searched = pathfinder.plan(def, from, to, asker.max_expansions, permit(asker, part))
	if path == nil then
		return nil
	end
	local orders: { Order } = {}
	for _, step in path.orders do
		table.insert(orders, { kind = kind, position = step.position })
	end
	return { orders = orders, complete = path.complete, searched = searched }
end

-- The orders of `way`, which takes `def` to `to` by orders of `kind`, or, when its search got nowhere, one of `kind`
-- straight at `to`: what is sent somewhere goes, whatever its route came to.
local function or_straight(way: Route, def: EntityDef, to: Vector3, kind: OrderKind): { Order }
	if #way.orders == 0 then
		return { { kind = kind, position = surface.position(def, to.X, to.Z) } }
	end
	return way.orders
end

-- The moves `def` makes from `from` on its way to within `reach` of `to` (`pathfinder.waypoints_to`), before the order
-- that takes it there, for `asker`'s `part`; nil when it needs a route and has none left this step.
local function waypoints(
	asker: Asker,
	part: number?,
	def: EntityDef,
	from: Vector3,
	to: Vector3,
	reach: number
): { Vector3 }?
	return pathfinder.waypoints_to(def, from, to, reach, asker.max_expansions, permit(asker, part))
end

snapshot.keep("paths", function()
	return { spent = spent }
end, function(saved)
	spent = saved.spent
end)

return table.freeze({
	begin_step = begin_step,
	route = route,
	or_straight = or_straight,
	waypoints = waypoints,
})
