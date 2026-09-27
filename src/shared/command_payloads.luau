--!strict
-- What a player's commands carry to the server, as the client sends them (client/orders.luau) and the server reads them
-- (server/commands.luau, which checks every field before believing any of it).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

type EntityId = types.EntityId

-- An order (IssueOrder).
export type IssuedOrder = {
	kind: order_kinds.Command,
	-- what is ordered, by entity id, and, parallel to it, each one's own spot (a formation or a spread order) and the
	-- route the client found for it (shared/order_routes.luau)
	ids: { EntityId },
	positions: { Vector3 }?,
	routes: { { Vector3 } }?,
	-- what it is aimed at: something on the field, or one spot for everyone, with a radius for an area
	target_id: EntityId?,
	position: Vector3?,
	radius: number?,
	-- after what is queued already, or before it all, or instead of it
	queue: boolean,
	front: boolean,
	-- an attack or ground attack that fires the manual-fire weapons (`Order.launch`)
	launch: boolean,
}

-- A building put down by builders (PlaceBlueprint).
export type PlacedBlueprint = {
	def_name: string,
	position: Vector3,
	facing: number?,
	ids: { EntityId },
	-- each builder's route to it, parallel to `ids`
	routes: { { Vector3 } }?,
	queue: boolean,
	front: boolean,
}

-- Something added to a lab's queue, `count` times (QueueProduction), at the back, or with `front` at the front.
export type QueuedProduction = {
	factory_id: EntityId,
	def_name: string,
	count: number?,
	front: boolean?,
}

-- Something taken off a lab's queue, the one at `index`, or the last without it (CancelProduction).
export type CancelledProduction = {
	factory_id: EntityId,
	index: number?,
}

return table.freeze({})
