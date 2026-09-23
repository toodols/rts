-- Remote handlers. Everything arriving here is untrusted: ownership, types and placement are all
-- re-checked against the simulation before anything is applied.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

local state = require(script.Parent.state)
local orders = require(script.Parent.orders)
local players = require(script.Parent.players)
local placement = require(script.Parent.placement)
local production = require(script.Parent.production)
local godmode = require(script.Parent.godmode)

type Entity = types.Entity
type EntityId = types.EntityId
type Order = types.Order
type OrderKind = types.OrderKind

local issue_order: RemoteEvent = ReplicatedStorage.Shared.IssueOrder
local queue_production: RemoteEvent = ReplicatedStorage.Shared.QueueProduction
local cancel_production: RemoteEvent = ReplicatedStorage.Shared.CancelProduction
local place_blueprint: RemoteEvent = ReplicatedStorage.Shared.PlaceBlueprint

local MAX_SELECTION = 250
local MAX_QUEUE_COUNT = 50

-- The client finds each unit's way and sends it with the order (`pathfinder.waypoints_to`); the server searches for
-- nothing and only checks it. A route longer than this is not taken.
local MAX_ROUTE_WAYPOINTS = 128

local VALID_ORDER_KINDS: { [string]: boolean } = {
	dgun = true,
	move = true,
	fight = true,
	attack = true,
	attack_ground = true,
	reclaim = true,
	resurrect = true,
	assist = true,
	guard = true,
	repair = true,
	load = true,
	unload = true,
	stop = true,
	area_reclaim = true,
	area_repair = true,
	area_resurrect = true,
	area_attack = true,
}

-- An area command is not aimed at anything: it is a circle, given as a center point and a radius.
local AREA_KINDS: { [string]: boolean } = {
	area_reclaim = true,
	area_repair = true,
	area_resurrect = true,
	area_attack = true,
}

-- Returns the entity only if this player's team owns it and it is active.
local function owned_entity(player: Player, id: unknown): Entity?
	if typeof(id) ~= "number" then
		return nil
	end
	local team = players.team_of(player)
	if team == nil then
		return nil
	end
	local entity = state.get(id)
	if entity == nil then
		return nil
	end
	-- in godmode every real team is yours; the neutral team 0 still belongs to nobody
	local owned = entity.team == team or (godmode.is_enabled() and entity.team ~= 0)
	if owned == false then
		return nil
	end
	return entity
end

-- `order` with the way to it that the client sent, `raw`, laid ahead of it as waypoints: moves, or for a fight, fight
-- waypoints, so it fights its way along all of it. The way is only taken if nothing blocks any leg of it
-- (`pathfinder.has_open_line`),
-- and the last leg too for a move or a fight, which walk right up to where they go; otherwise the order is given
-- without it. The leg from where the unit stands is not checked, since it has moved on since the client saw it.
local function with_route(entity: Entity, order: Order, raw: unknown): { Order }
	local def = unit_defs.get(entity.def_name)
	if typeof(raw) ~= "table" or def.max_speed == nil or def.air ~= nil then
		return { order }
	end
	local points = raw :: { unknown }
	if #points == 0 or #points > MAX_ROUTE_WAYPOINTS then
		return { order }
	end
	local kind: OrderKind = if order.kind == "fight" then "fight" else "move"
	local steps: { Order } = {}
	local previous: Vector3? = nil
	for _, point in points do
		if typeof(point) ~= "Vector3" or heightmap.in_bounds(point.X, point.Z) == false then
			return { order }
		end
		local at = unit_defs.surface_position(def, point.X, point.Z)
		if previous ~= nil and pathfinder.has_open_line(def, previous, at) == false then
			return { order }
		end
		table.insert(steps, { kind = kind, position = at, target_id = nil })
		previous = at
	end
	local walks_up_to = order.kind == "move" or order.kind == "fight"
	if
		walks_up_to
		and previous ~= nil
		and order.position ~= nil
		and pathfinder.has_open_line(def, previous, order.position) == false
	then
		return { order }
	end
	table.insert(steps, order)
	return steps
end

local function on_issue_order(player: Player, payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: any

	local kind = data.kind
	if typeof(kind) ~= "string" or VALID_ORDER_KINDS[kind] == nil then
		return
	end

	local ids = data.ids
	if typeof(ids) ~= "table" then
		return
	end

	local should_queue = data.queue == true
	local positions = if typeof(data.positions) == "table" then data.positions else nil
	local target_id = if typeof(data.target_id) == "number" then data.target_id else nil

	-- an attack, reclaim or assist order is meaningless without something to point at; moving and attacking
	-- the ground, fighting, and unloading, point at a place instead
	local needs_target = kind ~= "move"
		and kind ~= "dgun"
		and kind ~= "fight"
		and kind ~= "attack_ground"
		and kind ~= "unload"
		and kind ~= "stop"
		and AREA_KINDS[kind] == nil
	if needs_target and target_id == nil then
		return
	end
	if needs_target and state.get(target_id :: number) == nil then
		return
	end

	local radius: number? = nil
	if AREA_KINDS[kind] then
		if typeof(data.radius) ~= "number" or data.radius <= 0 then
			return
		end
		radius = data.radius
	end

	-- one spot for everyone, unlike a move, which gives each unit its own
	local ground: Vector3? = nil
	-- a fight, ground attack, or unload dragged out along a line gives every unit a point of its own instead
	local per_unit = positions ~= nil and (kind == "fight" or kind == "attack_ground" or kind == "unload")
	local at_a_point = kind == "fight"
		or kind == "attack_ground"
		or kind == "unload"
		or kind == "dgun"
		or AREA_KINDS[kind] == true
	if at_a_point and per_unit == false then
		local raw = data.position
		if typeof(raw) ~= "Vector3" or heightmap.in_bounds(raw.X, raw.Z) == false then
			return
		end
		ground = heightmap.ground_position(raw.X, raw.Z)
	end

	-- only your own team can be guarded; following an enemy would be a free look at where it goes. Anyone's can be loaded
	if kind == "guard" and owned_entity(player, target_id) == nil then
		return
	end

	-- each unit's way, parallel to ids
	local routes = if typeof(data.routes) == "table" then data.routes else nil
	local count = math.min(#ids, MAX_SELECTION)
	for index = 1, count do
		local entity = owned_entity(player, ids[index])
		if entity == nil then
			continue
		end
		-- a drone answers to its carrier alone
		if unit_defs.get(entity.def_name).drone == true then
			continue
		end
		-- a lab cannot carry out orders, but it keeps them in its queue like anything else, and each unit it makes
		-- takes a copy (see production's rally_order)
		local factory = unit_defs.is_factory(unit_defs.get(entity.def_name))
		-- an unfinished unit takes orders too: they wait in its queue until it is built
		if factory == false and unit_defs.takes_orders(unit_defs.get(entity.def_name)) == false then
			continue
		end

		-- stopping drops everything the unit was told to do, and leaves it standing where it is
		if kind == "stop" then
			entity.orders = {}
			continue
		end

		-- a lab has nothing to fire, load or unload, and its units are not there yet to do it
		if factory and (kind == "dgun" or kind == "load" or kind == "unload") then
			continue
		end

		-- only something with a manual weapon can be told to fire it; for anything else it would only clear its queue
		if kind == "dgun" and unit_defs.get(entity.def_name).manual_weapon == nil then
			continue
		end

		local order: Order = { kind = kind :: OrderKind, position = ground, target_id = target_id, radius = radius }

		if per_unit then
			local raw = if positions ~= nil then positions[index] else nil
			if typeof(raw) ~= "Vector3" or heightmap.in_bounds(raw.X, raw.Z) == false then
				continue
			end
			order.position = heightmap.ground_position(raw.X, raw.Z)
		end

		-- For reclaim orders, capture the target's current position so waypoints stay at the original
		-- location, not following the target as it moves or gets reclaimed
		if kind == "reclaim" and target_id ~= nil then
			local target = state.get(target_id)
			if target ~= nil then
				order.position = target.position
			end
		end

		if kind == "move" then
			-- positions run parallel to ids so each unit gets its own point on the formation line
			local raw = if positions ~= nil then positions[index] else nil
			if typeof(raw) ~= "Vector3" then
				continue
			end
			if heightmap.in_bounds(raw.X, raw.Z) == false then
				continue
			end
			-- a ship's waypoints are on the water's surface, and the rest are on the ground
			order.position = unit_defs.surface_position(unit_defs.get(entity.def_name), raw.X, raw.Z)
		end

		-- a lab's orders are handed to each unit it makes, which finds its own way from where it is (see production's
		-- rally_order)
		local front = data.front == true
		if factory then
			orders.issue(entity, { order }, should_queue, front)
			continue
		end
		orders.issue(
			entity,
			with_route(entity, order, if routes ~= nil then routes[index] else nil),
			should_queue,
			front
		)
	end
end

local function on_queue_production(player: Player, payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: any

	local factory = owned_entity(player, data.factory_id)
	if factory == nil then
		return
	end
	if typeof(data.def_name) ~= "string" then
		return
	end
	if unit_defs.defs[data.def_name] == nil then
		return
	end

	-- A factory's build orders always queue, whether or not shift was held.
	local count = if typeof(data.count) == "number" then math.floor(data.count) else 1
	count = math.clamp(count, 1, MAX_QUEUE_COUNT)
	for _ = 1, count do
		if production.enqueue(factory, data.def_name) == false then
			return
		end
	end
end

local function on_cancel_production(player: Player, payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: any

	local factory = owned_entity(player, data.factory_id)
	if factory == nil then
		return
	end
	local index = if typeof(data.index) == "number" then math.floor(data.index) else #factory.queue
	production.cancel(factory, index)
end

local function on_place_blueprint(player: Player, payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local data = payload :: any

	local team = players.team_of(player)
	if team == nil then
		return
	end
	if typeof(data.def_name) ~= "string" then
		return
	end
	local def = unit_defs.defs[data.def_name]
	if def == nil or def.kind ~= "building" then
		return
	end
	if typeof(data.position) ~= "Vector3" then
		return
	end

	local ids = data.ids
	if typeof(ids) ~= "table" then
		return
	end

	-- Only a builder that lists this def may order it, and only builders can pay it off.
	local builders: { Entity } = {}
	-- each builder's way to the site, as the client sent it alongside its id
	local routes = if typeof(data.routes) == "table" then data.routes else nil
	local builder_routes: { [Entity]: unknown } = {}
	for index = 1, math.min(#ids, MAX_SELECTION) do
		local entity = owned_entity(player, ids[index])
		if entity == nil then
			continue
		end
		local builder_def = unit_defs.get(entity.def_name)
		if builder_def.build_options == nil or table.find(builder_def.build_options, data.def_name) == nil then
			continue
		end
		if builder_def.assisting == false then
			continue
		end
		table.insert(builders, entity)
		builder_routes[entity] = if routes ~= nil then routes[index] else nil
	end
	if #builders == 0 then
		return
	end

	local facing = geometry.snap_facing(if typeof(data.facing) == "number" then data.facing else 0)
	local center = placement.resolve_center(data.def_name, data.position.X, data.position.Z, facing, builders[1].id)
	if center == nil then
		return
	end

	local placeable = placement.can_place(data.def_name, center, facing, nil, builders[1].team)
	if placeable == false then
		return
	end

	-- Nothing is placed yet. Each builder is sent to the spot, and the blueprint appears when the
	-- first of them gets there.
	local should_queue = data.queue == true
	local front = data.front == true
	for _, builder in builders do
		local order: Order = {
			kind = "build",
			position = center,
			target_id = nil,
			def_name = data.def_name,
			facing = facing,
		}
		orders.issue(builder, with_route(builder, order, builder_routes[builder]), should_queue, front)
	end
end

local function init()
	issue_order.OnServerEvent:Connect(on_issue_order)
	queue_production.OnServerEvent:Connect(on_queue_production)
	cancel_production.OnServerEvent:Connect(on_cancel_production)
	place_blueprint.OnServerEvent:Connect(on_place_blueprint)
end

return table.freeze({
	init = init,
	with_route = with_route,
})
