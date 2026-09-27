--!strict
-- Sends the orders a player gives, every kind of them, from the map, the HUD or a piloted unit alike: an order
-- (IssueOrder), a building to put up (PlaceBlueprint), or what a lab is to make (QueueProduction, CancelProduction). Each goes with the way every unit it is given to will go,
-- found here (shared/order_routes.luau) for the server to check rather than search for, and with where it goes in the
-- units' queues.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local UserInputService = game:GetService "UserInputService"

local types = require(ReplicatedStorage.Shared.types)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)
local order_routes = require(ReplicatedStorage.Shared.order_routes)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local order_path = require(ReplicatedStorage.Shared.order_path)
local command_payloads = require(ReplicatedStorage.Shared.command_payloads)

local world = require(ReplicatedStorage.Client.world)
local modifiers = require(ReplicatedStorage.Client.modifiers)

type EntityId = types.EntityId
type Command = order_kinds.Command

-- What an order is aimed at, as order_kinds' `aim` has it: something on the field, one spot for everyone, a spot of
-- its own for each unit (a formation, or a spot order spread along a line), a circle, or nothing.
export type Target =
	{ aim: "entity", id: EntityId }
	| { aim: "spot", position: Vector3 }
	| { aim: "spots", positions: { Vector3 } }
	| { aim: "area", position: Vector3, radius: number }
	| { aim: "none" }

-- Where an order goes in each unit's queue: instead of it, after it (`queue`), or before it all (`queue` and `front`).
export type Queueing = { queue: boolean, front: boolean }

local issue_order: RemoteEvent = ReplicatedStorage.Shared.IssueOrder
local place_blueprint: RemoteEvent = ReplicatedStorage.Shared.PlaceBlueprint
local queue_production: RemoteEvent = ReplicatedStorage.Shared.QueueProduction
local cancel_production: RemoteEvent = ReplicatedStorage.Shared.CancelProduction

-- An order that replaces whatever each unit was doing.
local NOW: Queueing = table.freeze({ queue = false, front = false })

-- Where an order given from the map goes: shift queues it, and space, held as well, puts it at the front.
local function from_keys(): Queueing
	return {
		queue = modifiers.shift_held(),
		front = UserInputService:IsKeyDown(Enum.KeyCode.Space),
	}
end

-- Where a unit starts out on an order: where it stands, or, for one added to the back of its queue, where the last
-- order already in it leaves it, as the server published it.
local function start_of(id: EntityId, queueing: Queueing): Vector3?
	local model = world.get(id)
	if model == nil then
		return nil
	end
	local path = entity_attrs.text(model, "path")
	local last = if queueing.queue and queueing.front == false and path ~= nil then order_path.last(path) else nil
	if last ~= nil then
		return Vector3.new(last.x, 0, last.z)
	end
	return world.position_of(model)
end

-- The waypoints unit `id` goes through from `from` on its way to an order of `kind` at `destination`.
local function waypoints(
	id: EntityId,
	from: Vector3,
	kind: Command,
	launch: boolean,
	destination: Vector3,
	radius: number?
): { Vector3 }
	local def = world.def_of_id(id)
	if def == nil then
		return {}
	end
	return order_routes.waypoints(def, from, kind, launch, destination, radius)
end

-- Where the unit at `index` is going for `target`: what it is aimed at as it stands now, or its spot.
local function destination_of(target: Target, index: number): Vector3?
	if target.aim == "entity" then
		local model = world.get(target.id)
		return if model ~= nil then world.position_of(model) else nil
	elseif target.aim == "spot" or target.aim == "area" then
		return target.position
	elseif target.aim == "spots" then
		return target.positions[index]
	end
	return nil
end

-- The way each of `ids` goes to `target`, in the same order.
local function routes_for(
	ids: { EntityId },
	kind: Command,
	target: Target,
	queueing: Queueing,
	launch: boolean
): { { Vector3 } }
	local radius = if target.aim == "area" then target.radius else nil
	local result = table.create(#ids)
	for index, id in ids do
		local destination = destination_of(target, index)
		local from = start_of(id, queueing)
		result[index] = if destination ~= nil and from ~= nil
			then waypoints(id, from, kind, launch, destination, radius)
			else {}
	end
	return result
end

-- Gives `ids` an order of `kind` at `target`, going into their queues as `queueing` says; `launch` makes an attack a
-- launch. Nothing is sent for nobody.
local function send(kind: Command, ids: { EntityId }, target: Target, queueing: Queueing, launch: boolean?)
	if #ids == 0 then
		return
	end
	local payload: command_payloads.IssuedOrder = {
		kind = kind,
		ids = ids,
		queue = queueing.queue,
		front = queueing.front,
		launch = launch == true,
	}
	if target.aim == "entity" then
		payload.target_id = target.id
	elseif target.aim == "spot" then
		payload.position = target.position
	elseif target.aim == "spots" then
		payload.positions = target.positions
	elseif target.aim == "area" then
		payload.position = target.position
		payload.radius = target.radius
	end
	if target.aim ~= "none" then
		payload.routes = routes_for(ids, kind, target, queueing, launch == true)
	end
	issue_order:FireServer(payload)
end

-- Sends `builders` to put `def_name` up at each of `centers`, turned to `facing`, going into their queues as
-- `queueing` says. Each builder's way to each site is found in the order they will be built, each from the one
-- before. They go out in order, or backwards when they go on the front of the queue, so the first place ends up first.
local function place(def_name: string, builders: { EntityId }, centers: { Vector3 }, facing: number, queueing: Queueing)
	if #builders == 0 or #centers == 0 then
		return
	end
	local ways: { { { Vector3 } } } = {}
	local starts: { [EntityId]: Vector3? } = {}
	for _, id in builders do
		starts[id] = start_of(id, queueing)
	end
	for index, center in centers do
		local each = table.create(#builders)
		for position, id in builders do
			local from = starts[id]
			each[position] = if from ~= nil then waypoints(id, from, "build", false, center, nil) else {}
			starts[id] = center
		end
		ways[index] = each
	end
	local front = queueing.front
	local first = if front then #centers else 1
	local last = if front then 1 else #centers
	for index = first, last, if front then -1 else 1 do
		local blueprint: command_payloads.PlacedBlueprint = {
			def_name = def_name,
			position = centers[index],
			facing = facing,
			ids = builders,
			routes = ways[index],
			queue = queueing.queue,
			front = front,
		}
		place_blueprint:FireServer(blueprint)
	end
end

-- Adds `count` of `def_name` to the back of the queue of the lab `factory_id`, or with `front` to the front of it.
local function queue(factory_id: EntityId, def_name: string, count: number, front: boolean)
	local sent: command_payloads.QueuedProduction =
		{ factory_id = factory_id, def_name = def_name, count = count, front = front }
	queue_production:FireServer(sent)
end

-- Takes what is at `index` in the queue of the lab `factory_id` off it, or the last thing without `index`.
local function cancel(factory_id: EntityId, index: number?)
	local sent: command_payloads.CancelledProduction = { factory_id = factory_id, index = index }
	cancel_production:FireServer(sent)
end

return table.freeze({
	NOW = NOW,
	from_keys = from_keys,
	send = send,
	place = place,
	queue = queue,
	cancel = cancel,
})
