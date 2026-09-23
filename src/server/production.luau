-- Factory production. An active factory with a non-empty queue keeps a single blueprint alive inside
-- its own footprint - at its centre, or its def's `production_offset` from it - and pours its buildpower
-- into that blueprint until it finishes. The blueprint does not count as in the factory's way.
--
-- A finished unit drives straight out through the doorway before it does anything else. Until it is
-- clear of the factory's footprint the two pass through each other (`movement.begin_exit`), and its
-- orders, the factory's own among them, wait: nothing a player tells it cuts its way out short.
--
-- While the spot is occupied - by the unit still on its way out, or anything else - the factory waits
-- and retries next tick. If it has waited PRODUCTION_BLOCK_LIMIT seconds, its own units standing in the
-- doorway are ordered to move aside.
--
-- A blueprint made here belongs to the factory's queue: cancelling the entry being built destroys
-- the blueprint on the spot and refunds everything paid into it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

local state = require(script.Parent.state)
local placement = require(script.Parent.placement)
local construction = require(script.Parent.construction)
local economy = require(script.Parent.economy)
local movement = require(script.Parent.movement)

type Entity = types.Entity
type EntityId = types.EntityId

-- The blueprint each factory is currently working on, keyed by factory id. Held outside the
-- entity so that Entity stays a flat serialisable record.
local in_progress: { [EntityId]: EntityId } = {}
-- How long each factory's next unit has been unable to appear, in seconds.
local blocked_for: { [EntityId]: number } = {}
-- Where each unit on its way out of its factory is driving to, just past the doorway.
local exit_points: { [EntityId]: Vector3 } = {}

-- The most cells a search for a unit's way to its factory's rally point may settle, the same as for a player's move.
local RALLY_MAX_EXPANSIONS = 8000

-- The way out of a factory, through its doorway: the way it faces.
local function doorway_vector(facing: number): Vector3
	return Vector3.new(math.sin(facing), 0, math.cos(facing))
end

-- Where the next unit appears: inside the factory's footprint, its def's `production_offset` from the centre.
local function production_spot(factory: Entity, product_def_name: string): Vector3
	local offset = unit_defs.get(factory.def_name).production_offset or Vector2.zero
	local out = doorway_vector(factory.facing)
	local right = Vector3.new(-out.Z, 0, out.X)
	local spot = factory.position + right * offset.X + out * offset.Y
	return placement.ground_center(product_def_name, spot.X, spot.Z)
end

-- Where a unit of `product_def` at `from` inside the factory drives to on its way out: straight out through the
-- doorway, until it is clear of the footprint by PRODUCTION_SPOT_GAP.
local function exit_point(factory: Entity, product_def: types.EntityDef, from: Vector3): Vector3
	local out = doorway_vector(factory.facing)
	local half = placement.half_extents_for(factory)
	-- distance from the factory centre to its own edge along `out`
	local edge = math.abs(out.X) * half.X + math.abs(out.Z) * half.Y
	local depth = geometry.flatten(from - factory.position):Dot(out)
	-- far enough that its footprint, which it is let go by, is clear too, and not only its collider
	local footprint = unit_defs.footprint_half_extents(product_def)
	local reach = math.max(unit_defs.collider_radius(product_def), footprint.X, footprint.Y)
	local point = from + out * (edge + reach + config.PRODUCTION_SPOT_GAP - depth)
	return unit_defs.surface_position(product_def, point.X, point.Z)
end

-- Once a unit is finished it is told to walk on from the doorway, `from`, so the next one has room to get out,
-- unless it was already given orders while it was being built, which are then carried out instead. Otherwise it
-- takes a copy of the factory's own orders, which the factory never carries out itself. The factory's
-- moves and fights find their own way, as a player's do (`pathfinder.route`), each from where the one before it
-- leaves the unit, a fight as a chain of fight waypoints.
local function rally_order(factory: Entity, product: Entity, from: Vector3)
	if #product.orders > 0 then
		return
	end
	local given = factory.orders
	if #given > 0 then
		local product_def = unit_defs.get(product.def_name)
		for _, order in given do
			local copy = table.clone(order)
			if copy.position ~= nil then
				copy.position = unit_defs.surface_position(product_def, copy.position.X, copy.position.Z)
			end
			if
				(copy.kind == "move" or copy.kind == "fight")
				and copy.position ~= nil
				and product_def.max_speed ~= nil
			then
				local route = pathfinder.route(product_def, from, copy.position, RALLY_MAX_EXPANSIONS)
				for _, step in route do
					step.kind = copy.kind
					table.insert(product.orders, step)
				end
				from = copy.position
				continue
			end
			table.insert(product.orders, copy)
			if copy.position ~= nil then
				from = copy.position
			end
		end
		return
	end
	local destination = from + doorway_vector(factory.facing) * config.PRODUCTION_RALLY_GAP
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

-- Orders every unit of the factory's own team that is standing in the doorway, where the next unit would drive
-- out of it, to move clear, ahead of whatever else it was doing.
local function vacate_blockers(factory: Entity, product_def_name: string, spot: Vector3)
	local product_def = unit_defs.get(product_def_name)
	local product_half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(product_def), factory.facing)
	local forward = doorway_vector(factory.facing)
	spot = exit_point(factory, product_def, spot)

	for _, other in state.all() do
		if other.alive == false or other.kind ~= "unit" or other.state ~= "active" or other.team ~= factory.team then
			continue
		end
		if movement.exiting_from(other.id) ~= nil then
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
			-- finished this tick's predecessor: send it out and move on
			local way_out = exit_point(factory, unit_defs.get(current.def_name), current.position)
			exit_points[current.id] = way_out
			movement.begin_exit(current, factory)
			rally_order(factory, current, way_out)
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
	local placeable = placement.can_place(next_def_name, spot, factory.facing, factory.id)
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

-- Drives every unit on its way out of its factory on toward the doorway, and lets it go once it is clear of the
-- footprint, or the factory is gone.
local function drive_exits()
	for id, point in exit_points do
		local unit = state.get(id)
		if unit == nil or unit.alive == false then
			exit_points[id] = nil
			movement.end_exit(id)
			continue
		end
		local factory_id = movement.exiting_from(id)
		local factory = if factory_id ~= nil then state.get(factory_id) else nil
		local inside = factory ~= nil
			and factory.alive
			and geometry.aabb_overlap(
				unit.position,
				placement.half_extents_for(unit),
				factory.position,
				placement.half_extents_for(factory),
				0
			)
		if inside == false then
			exit_points[id] = nil
			movement.end_exit(id)
			continue
		end
		movement.set_goal(unit, point, config.ARRIVAL_RADIUS, true)
	end
end

local function tick(delta: number)
	drive_exits()
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

local function forget(factory_id: EntityId)
	in_progress[factory_id] = nil
	blocked_for[factory_id] = nil
end

local function current_blueprint(factory_id: EntityId): EntityId?
	return in_progress[factory_id]
end

-- Whether the factory has a unit to start and cannot put its blueprint down, for something standing where it goes.
local function is_blocked(factory_id: EntityId): boolean
	return blocked_for[factory_id] ~= nil
end

return table.freeze({
	tick = tick,
	enqueue = enqueue,
	cancel = cancel,
	forget = forget,
	production_spot = production_spot,
	current_blueprint = current_blueprint,
	is_blocked = is_blocked,
})
