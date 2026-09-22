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

-- A pathfinding order searches for a route for every unit in it, and a search is not free, so each is given a
-- share of the tick: at most this many cells settled, and only the first few units of a big selection get a
-- search of their own. The rest are sent straight to the spot, as a move would.
local PATH_MAX_EXPANSIONS = 8000
local PATH_MAX_SEARCHES = 12

-- `path` is not an order itself: it is a request for the move orders that make up a route to a spot.
local VALID_ORDER_KINDS: { [string]: boolean } = {
	path = true,
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

-- The move orders that take `entity` to `to`. A route that is being queued starts where the unit's last
-- order leaves it, and one that is not starts where it stands. With no search left to spend it is one move
-- straight there.
local function route_to(entity: Entity, to: Vector3, after_queue: boolean, search_left: boolean): { Order }
	local def = unit_defs.get(entity.def_name)
	if search_left == false then
		return { { kind = "move", position = unit_defs.surface_position(def, to.X, to.Z) } }
	end
	local from = entity.position
	if after_queue then
		local last = entity.orders[#entity.orders]
		if last ~= nil and last.position ~= nil then
			from = last.position
		end
	end
	return pathfinder.find_path(def, from, to, PATH_MAX_EXPANSIONS).orders
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
		and kind ~= "path"
		and kind ~= "dgun"
		and kind ~= "fight"
		and kind ~= "attack_ground"
		and kind ~= "unload"
		and kind ~= "stop"
	if needs_target and target_id == nil then
		return
	end
	if needs_target and state.get(target_id :: number) == nil then
		return
	end

	-- one spot for everyone, unlike a move, which gives each unit its own
	local ground: Vector3? = nil
	-- a fight, ground attack, path, or unload dragged out along a line gives every unit a point of its own instead
	local per_unit = positions ~= nil and (kind == "fight" or kind == "attack_ground" or kind == "path" or kind == "unload")
	local at_a_point = kind == "fight"
		or kind == "attack_ground"
		or kind == "unload"
		or kind == "path"
		or kind == "dgun"
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

	local searches = 0
	local count = math.min(#ids, MAX_SELECTION)
	for index = 1, count do
		local entity = owned_entity(player, ids[index])
		if entity == nil then
			continue
		end
		-- a lab cannot carry out orders, but what it is told is remembered and handed to each unit it makes, and
		-- stopping forgets it
		-- a drone answers to its carrier alone
		if unit_defs.get(entity.def_name).drone == true then
			continue
		end
		local factory = unit_defs.is_factory(unit_defs.get(entity.def_name))
		if factory and kind == "stop" then
			production.clear_rally(entity)
			continue
		end
		-- an unfinished unit takes orders too: they wait in its queue until it is built
		if factory == false and unit_defs.takes_orders(unit_defs.get(entity.def_name)) == false then
			continue
		end

		-- stopping drops everything the unit was told to do, and leaves it standing where it is
		if kind == "stop" then
			entity.orders = {}
			continue
		end

		-- a route is a chain of moves, so it is issued as the orders it is made of and not as an order of its own
		if kind == "path" and factory then
			-- a lab has no route to work out: what it makes is sent to the spot
			local path_target: Vector3? = ground
			if per_unit then
				local raw = if positions ~= nil then positions[index] else nil
				if typeof(raw) ~= "Vector3" or heightmap.in_bounds(raw.X, raw.Z) == false then
					continue
				end
				path_target = heightmap.ground_position(raw.X, raw.Z)
			end
			if path_target ~= nil then
				production.set_rally(entity, { kind = "move", position = path_target, target_id = nil }, should_queue)
			end
			continue
		end
		if kind == "path" then
			local path_target: Vector3? = ground
			if per_unit then
				local raw = if positions ~= nil then positions[index] else nil
				if typeof(raw) ~= "Vector3" or heightmap.in_bounds(raw.X, raw.Z) == false then
					continue
				end
				path_target = heightmap.ground_position(raw.X, raw.Z)
			end
			if unit_defs.get(entity.def_name).max_speed == nil or path_target == nil then
				continue
			end
			local front = data.front == true
			local route = route_to(entity, path_target, should_queue and front == false, searches < PATH_MAX_SEARCHES)
			searches += 1
			if #route > 0 then
				orders.issue(entity, route, should_queue, front)
			end
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

		local order: Order = { kind = kind :: OrderKind, position = ground, target_id = target_id }

		if per_unit then
			local raw = if positions ~= nil then positions[index] else nil
			if typeof(raw) ~= "Vector3" or heightmap.in_bounds(raw.X, raw.Z) == false then
				continue
			end
			order.position = heightmap.ground_position(raw.X, raw.Z)
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

		if factory then
			production.set_rally(entity, order, should_queue)
			continue
		end
		orders.issue(entity, { order }, should_queue, data.front == true)
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
	for _, builder in builders do
		local order: Order = {
			kind = "build",
			position = center,
			target_id = nil,
			def_name = data.def_name,
			facing = facing,
		}
		orders.issue(builder, { order }, should_queue, data.front == true)
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
})
