-- Factory production. An active factory with a non-empty queue keeps a single blueprint alive in
-- the spot in front of it and pours its buildpower into that blueprint until it finishes.
--
-- If the spot is occupied - by the unit it just built, a wreck, or anything wandering through -
-- the factory waits and retries next tick. If one of its own units has been standing in the way for
-- PRODUCTION_BLOCK_LIMIT seconds, that unit is ordered to move aside.
--
-- A blueprint made here belongs to the factory's queue: cancelling the entry being built destroys
-- the blueprint on the spot and refunds everything paid into it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local placement = require(script.Parent.placement)
local construction = require(script.Parent.construction)
local economy = require(script.Parent.economy)

type Entity = types.Entity
type EntityId = types.EntityId

-- The blueprint each factory is currently working on, keyed by factory id. Held outside the
-- entity so that Entity stays a flat serialisable record.
local in_progress: { [EntityId]: EntityId } = {}
-- Where each factory sends what it makes, in order: the move orders it was given.
-- What a factory has been told to have its units do, in order, once they are built.
local rallies: { [EntityId]: { types.Order } } = {}
-- How long each factory's next unit has been unable to appear, in seconds.
local blocked_for: { [EntityId]: number } = {}

local function forward_vector(facing: number): Vector3
	return Vector3.new(math.sin(facing), 0, math.cos(facing))
end

-- Where the next unit appears: clear of the factory's own footprint along its facing.
local function production_spot(factory: Entity, product_def_name: string): Vector3
	local product_def = unit_defs.get(product_def_name)

	local factory_half = placement.half_extents_for(factory)
	local forward = forward_vector(factory.facing)
	-- distance from the factory centre to its own edge along `forward`
	local edge = math.abs(forward.X) * factory_half.X + math.abs(forward.Z) * factory_half.Y
	local product_reach = unit_defs.collider_radius(product_def)

	local offset = edge + product_reach + config.PRODUCTION_SPOT_GAP
	local spot = factory.position + forward * offset
	return placement.ground_center(product_def_name, spot.X, spot.Z)
end

-- Once a unit is finished it is told to walk clear so the next one has room to appear, unless it
-- was already given orders while it was being built, which are then carried out instead.
local function rally_order(factory: Entity, product: Entity)
	if #product.orders > 0 then
		return
	end
	local given = rallies[factory.id]
	if given ~= nil and #given > 0 then
		local product_def = unit_defs.get(product.def_name)
		for _, order in given do
			local copy = table.clone(order)
			if copy.position ~= nil then
				copy.position = unit_defs.surface_position(product_def, copy.position.X, copy.position.Z)
			end
			table.insert(product.orders, copy)
		end
		return
	end
	local forward = forward_vector(factory.facing)
	local destination = product.position + forward * config.PRODUCTION_RALLY_GAP
	product.orders = {
		{
			kind = "move",
			position = unit_defs.surface_position(unit_defs.get(product.def_name), destination.X, destination.Z),
			target_id = nil,
		},
	}
end

local function enqueue(factory: Entity, def_name: string): boolean
	local factory_def = unit_defs.get(factory.def_name)
	local builds = factory_def.build_options
	if builds == nil then
		return false
	end
	if table.find(builds, def_name) == nil then
		return false
	end
	table.insert(factory.queue, def_name)
	return true
end

-- Removes one entry. A negative index counts from the end of the queue. The front entry is the unit
-- being built: cancelling it destroys its blueprint at once and refunds everything paid into it.
local function cancel(factory: Entity, index: number): boolean
	local resolved = if index < 0 then #factory.queue + 1 + index else index
	if factory.queue[resolved] == nil then
		return false
	end
	table.remove(factory.queue, resolved)

	if resolved == 1 then
		local current_id = in_progress[factory.id]
		local current = if current_id ~= nil then state.get(current_id) else nil
		if current ~= nil and current.state == "blueprint" then
			economy.add_metal(current.team, current.metal_paid)
			economy.add_energy(current.team, current.energy_paid)
			state.mark_dead(current)
		end
		in_progress[factory.id] = nil
	end
	return true
end

-- Orders every unit of the factory's own team that is standing where the next unit would appear to
-- move clear, ahead of whatever else it was doing.
local function vacate_blockers(factory: Entity, product_def_name: string, spot: Vector3)
	local product_def = unit_defs.get(product_def_name)
	local product_half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(product_def), factory.facing)
	local forward = forward_vector(factory.facing)

	for _, other in state.all() do
		if other.alive == false or other.kind ~= "unit" or other.state ~= "active" or other.team ~= factory.team then
			continue
		end
		if geometry.aabb_overlap(spot, product_half, other.position, placement.half_extents_for(other), 0) == false then
			continue
		end

		-- away from the spot, but never back toward the factory itself
		local away = geometry.flatten(other.position - spot)
		if away.Magnitude < 1e-3 or away:Dot(forward) < 0 then
			away = forward
		else
			away = away.Unit
		end
		local clearance = unit_defs.collider_radius(product_def)
			+ unit_defs.collider_radius(unit_defs.get(other.def_name))
			+ config.PRODUCTION_RALLY_GAP
		local destination = spot + away * clearance
		table.insert(other.orders, 1, {
			kind = "move",
			position = unit_defs.surface_position(unit_defs.get(other.def_name), destination.X, destination.Z),
			target_id = nil,
		})
	end
end

local function tick_factory(factory: Entity, delta: number)
	if factory.state ~= "active" then
		return
	end
	local factory_def = unit_defs.get(factory.def_name)
	if factory_def.build_options == nil or factory_def.buildpower == nil then
		return
	end

	local current_id = in_progress[factory.id]
	if current_id ~= nil then
		local current = state.get(current_id)
		if current == nil then
			-- the blueprint was destroyed or reclaimed out from under us; start the item over
			in_progress[factory.id] = nil
		elseif current.state == "blueprint" then
			blocked_for[factory.id] = nil
			construction.request(factory, current)
			return
		else
			-- finished this tick's predecessor: release it and move on
			rally_order(factory, current)
			in_progress[factory.id] = nil
			table.remove(factory.queue, 1)
			return
		end
	end

	local next_def_name = factory.queue[1]
	if next_def_name == nil then
		blocked_for[factory.id] = nil
		return
	end

	local spot = production_spot(factory, next_def_name)
	local placeable = placement.can_place(next_def_name, spot, factory.facing, nil)
	if placeable == false then
		-- blocked; hold the queue and try again next tick, and if it goes on for too long, tell the
		-- factory's own units in the way to move. Restarting the count gives them time to do it.
		local waited = (blocked_for[factory.id] or 0) + delta
		if waited >= config.PRODUCTION_BLOCK_LIMIT then
			waited = 0
			vacate_blockers(factory, next_def_name, spot)
		end
		blocked_for[factory.id] = waited
		return
	end
	blocked_for[factory.id] = nil

	local blueprint = state.create_entity(next_def_name, factory.team, spot, factory.facing, "blueprint")
	in_progress[factory.id] = blueprint.id
	construction.request(factory, blueprint)
end

local function tick(delta: number)
	for _, entity in state.all() do
		if entity.alive == false then
			continue
		end
		if #entity.queue == 0 and in_progress[entity.id] == nil then
			continue
		end
		tick_factory(entity, delta)
	end
end

-- An order given to a factory: what it makes carries it out. Queued, it goes after the others.
local function set_rally(factory: Entity, order: types.Order, queue: boolean)
	local given = rallies[factory.id]
	if given == nil or queue == false then
		given = {}
		rallies[factory.id] = given
	end
	table.insert(given, order)
end

local function clear_rally(factory: Entity)
	rallies[factory.id] = nil
end

local function forget(factory_id: EntityId)
	rallies[factory_id] = nil
	in_progress[factory_id] = nil
	blocked_for[factory_id] = nil
end

local function current_blueprint(factory_id: EntityId): EntityId?
	return in_progress[factory_id]
end

return table.freeze({
	tick = tick,
	enqueue = enqueue,
	cancel = cancel,
	forget = forget,
	set_rally = set_rally,
	clear_rally = clear_rally,
	production_spot = production_spot,
	current_blueprint = current_blueprint,
})
