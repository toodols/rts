-- Order execution. Every tick each unit looks at the front of its queue, decides where it wants
-- to be, and registers whatever work that order implies. Orders are popped as they complete, so
-- an empty queue means idle.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local state = require(script.Parent.state)
local movement = require(script.Parent.movement)
local combat = require(script.Parent.combat)
local reclaim = require(script.Parent.reclaim)
local resurrection = require(script.Parent.resurrection)
local construction = require(script.Parent.construction)
local placement = require(script.Parent.placement)
local transport = require(script.Parent.transport)
local alliances = require(script.Parent.alliances)

type Entity = types.Entity
type Order = types.Order

-- Close in to a little inside the nominal range so that a unit drifting by a stud does not
-- immediately fall back out of range and start chasing again.
local RANGE_MARGIN = 0.85

-- Blueprints started this tick. New entities only join `state.all()` when the step ends, so
-- builders arriving at the same spot in the same tick would not see each other's blueprint there.
local started_this_tick: { Entity } = {}
-- The length of the tick being run, for timing how long a builder has been stuck.
local tick_delta = 0

-- Gives `entity` new orders. By default they replace its queue; `queue` adds them to the back, and
-- `front` puts them at the front, pushing whatever it was doing and everything after it back.
local function issue(entity: Entity, orders: { Order }, queue: boolean, front: boolean)
	if front then
		for index, order in orders do
			table.insert(entity.orders, index, order)
		end
	elseif queue then
		for _, order in orders do
			table.insert(entity.orders, order)
		end
	else
		entity.orders = table.clone(orders)
	end
end

local function pop(entity: Entity)
	table.remove(entity.orders, 1)
end

local function is_immobile(entity: Entity): boolean
	return unit_defs.get(entity.def_name).max_speed == nil
end

-- How far `entity` reaches to work: its own reach if it has one, like a construction turret, or the
-- usual range for units.
local function work_range(entity: Entity, usual: number): number
	local reach = unit_defs.get(entity.def_name).build_range
	if reach ~= nil then
		return reach
	end
	return usual
end

-- Walks toward `position`, stopping `stop_radius` short. Returns whether it is already there. Something
-- that cannot move stays where it is, so for it this only ever answers whether the target is in reach.
local function approach(entity: Entity, position: Vector3, stop_radius: number): boolean
	if geometry.distance_2d(entity.position, position) <= stop_radius then
		return true
	end
	if is_immobile(entity) == false then
		movement.set_goal(entity, position, stop_radius, false)
	end
	return false
end

-- How many seconds of travel ahead of a waypoint a unit begins turning onto the next one, when it has
-- one to go to.
local WAYPOINT_LOOKAHEAD = 0.5

-- Walks a chain of move orders. A unit with another waypoint after this one flows through it: it turns
-- onto the next as it gets close, at full speed, instead of stopping on every point along the way.
-- Moving on to the next order within the same tick matters as much as not braking: goals are cleared
-- every tick, so popping an order and leaving the next for the following tick would drop the unit's
-- goal for a tick at each waypoint, and it would coast.
local function run_move(entity: Entity, first: Order)
	local def = unit_defs.get(entity.def_name)
	local speed = if def.max_speed ~= nil then def.max_speed else 0
	local order = first

	for _ = 1, #entity.orders do
		local position = order.position
		if position == nil or is_immobile(entity) then
			pop(entity)
		else
			local following = entity.orders[2]
			if following ~= nil and following.kind == "move" and following.position ~= nil then
				local turn_radius = math.max(config.ARRIVAL_RADIUS, speed * WAYPOINT_LOOKAHEAD)
				if geometry.distance_2d(entity.position, position) > turn_radius then
					movement.set_goal(entity, position, config.ARRIVAL_RADIUS, true)
					return
				end
				pop(entity)
			else
				-- the last waypoint: slow down and stop on it
				if approach(entity, position, config.ARRIVAL_RADIUS) then
					pop(entity)
				end
				return
			end
		end

		local next_order = entity.orders[1]
		if next_order == nil or next_order.kind ~= "move" then
			return
		end
		order = next_order
	end
end

-- Whether it is the kind of aircraft that attacks by flying over what it attacks, and not by stopping to
-- hover in range of it.
local function is_bomber(def: types.EntityDef): boolean
	return def.air ~= nil and def.air.bombing_runs == true
end

-- A bombing run: it flies at `point` at full speed, over it and on past, and drops bombs on whatever it
-- crosses as it goes (`combat` does that, whenever something is beneath it). Once it has flown over the
-- point it holds its heading, and only turns back for another pass when it is clear of it, which is what
-- makes it a pass and not a tight circle round the point.
local function run_bombing(entity: Entity, point: Vector3)
	local to_point = geometry.flatten(point - entity.position)
	local heading = geometry.flatten(entity.velocity)

	local goal: Vector3
	if heading.Magnitude > 1 and to_point:Dot(heading) < 0 and to_point.Magnitude < config.BOMBER_RUN_OUT then
		goal = entity.position + heading.Unit * config.BOMBER_RUN_OUT
	else
		local ahead = if to_point.Magnitude > 1e-3
			then to_point.Unit
			else Vector3.new(math.sin(entity.facing), 0, math.cos(entity.facing))
		goal = point + ahead * config.BOMBER_RUN_OUT
	end
	movement.set_goal(entity, goal, config.ARRIVAL_RADIUS, true)
end

-- Fighting: walk to the point the way a move does, but whenever there is something to shoot at, stand still
-- and shoot it (`combat` picks what and does the shooting, as it does for anything with no target
-- ordered), and set off again once there is nothing left. The order ends on arrival. A unit that cannot
-- shoot has nothing to stop for, and neither has a bomber, which cannot stop, so for them it is a move.
local function run_fight(entity: Entity, order: Order)
	local position = order.position
	if position == nil or is_immobile(entity) then
		pop(entity)
		return
	end
	if geometry.distance_2d(entity.position, position) <= config.ARRIVAL_RADIUS then
		pop(entity)
		return
	end

	local def = unit_defs.get(entity.def_name)
	if unit_defs.attack_range(def) ~= nil and is_bomber(def) == false and combat.has_target(entity) then
		return
	end
	approach(entity, position, config.ARRIVAL_RADIUS)
end

local function run_attack(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	local def = unit_defs.get(entity.def_name)
	if target == nil or combat.is_enemy(entity, target) == false then
		combat.set_forced_target(entity, nil)
		pop(entity)
		return
	end
	-- an order to shoot at something its weapon cannot be turned on, like a fighter told to attack a
	-- tank, is no order at all
	if def.weapon ~= nil and combat.can_target(def.weapon, target) == false then
		combat.set_forced_target(entity, nil)
		pop(entity)
		return
	end

	combat.set_forced_target(entity, target.id)

	-- a unit with turrets is armed too, and closes in on what its longest one reaches
	local reach = unit_defs.attack_range(def)
	if reach == nil then
		-- unarmed units treat an attack order as a move onto the target
		approach(entity, target.position, config.ARRIVAL_RADIUS)
		if is_immobile(entity) then
			pop(entity)
		end
		return
	end
	if is_bomber(def) then
		run_bombing(entity, target.position)
		return
	end
	approach(entity, target.position, reach * RANGE_MARGIN)
end

-- Attacking the ground: close in until the point is in range, then keep shooting at it. Nothing ends the
-- order but another one, since there is no target to run out of; only a unit that cannot shoot drops it,
-- or one whose weapon only shoots at aircraft.
local function run_attack_ground(entity: Entity, order: Order)
	local position = order.position
	local def = unit_defs.get(entity.def_name)
	local reach = unit_defs.attack_range(def)
	if position == nil or reach == nil or (def.weapon ~= nil and def.weapon.target_layer == "air") then
		combat.set_forced_target(entity, nil)
		pop(entity)
		return
	end

	combat.set_forced_ground(entity, position)
	if is_bomber(def) then
		run_bombing(entity, position)
		return
	end
	approach(entity, position, reach * RANGE_MARGIN)
end

-- The commander's disintegrator at a point: close in until the point is within the weapon's range, then fire
-- as soon as it is ready and that is the order done. A weapon that is still reloading, or a team that is short
-- of the energy for it, is waited for, but a shot that a commander is in the way of is dropped, since nothing
-- is going to change that. A unit with no manual weapon drops it.
local function run_dgun(entity: Entity, order: Order)
	local position = order.position
	local weapon = unit_defs.get(entity.def_name).manual_weapon
	if position == nil or weapon == nil then
		pop(entity)
		return
	end
	if approach(entity, position, weapon.range * RANGE_MARGIN) == false then
		return
	end
	if combat.manual_fire(entity, position) ~= "waiting" then
		pop(entity)
	end
end

local function run_reclaim(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	if target == nil then
		pop(entity)
		return
	end
	if reclaim.can_reclaim(entity, target) == false then
		pop(entity)
		return
	end
	if approach(entity, target.position, work_range(entity, config.RECLAIM_RANGE) * RANGE_MARGIN) then
		reclaim.request(entity, target)
	elseif is_immobile(entity) then
		-- out of reach and unable to move, so it never will be
		pop(entity)
	end
end

local function run_resurrect(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	if target == nil or resurrection.can_resurrect(entity, target) == false then
		pop(entity)
		return
	end
	if approach(entity, target.position, work_range(entity, config.RESURRECT_RANGE) * RANGE_MARGIN) then
		resurrection.request(entity, target)
	elseif is_immobile(entity) then
		pop(entity)
	end
end

local function run_assist(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	if target == nil or target.state ~= "blueprint" then
		pop(entity)
		return
	end
	local def = unit_defs.get(entity.def_name)
	if def.assisting == false or def.buildpower == nil then
		pop(entity)
		return
	end
	if approach(entity, target.position, work_range(entity, config.BUILD_RANGE) * RANGE_MARGIN) then
		construction.request(entity, target)
	elseif is_immobile(entity) then
		pop(entity)
	end
end

-- Repairing: walk up to a damaged friendly, or an ally's, and restore its health until it is whole. The order ends
-- when the target is full, gone, or no longer something that can be repaired.
local function run_repair(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	local def = unit_defs.get(entity.def_name)
	if
		target == nil
		or target.alive == false
		or target.id == entity.id
		or alliances.are_allied(entity.team, target.team) == false
		or target.kind == "wreck"
		or target.state ~= "active"
		or target.health >= target.max_health
		or def.repairing == false
		or def.buildpower == nil
	then
		pop(entity)
		return
	end
	if approach(entity, target.position, work_range(entity, config.BUILD_RANGE) * RANGE_MARGIN) then
		construction.repair(entity, target, config.TICK_DELTA)
	elseif is_immobile(entity) then
		pop(entity)
	end
end

-- Guarding: stay with a friendly entity. A builder that can assist instead works on whatever the
-- guarded entity is building or reclaiming, and falls back to following when it is doing neither.
local function run_guard(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	if target == nil or target.alive == false or target.id == entity.id or target.team ~= entity.team then
		pop(entity)
		return
	end

	local def = unit_defs.get(entity.def_name)
	if def.assisting and def.buildpower ~= nil then
		local blueprint_id = construction.recent_target_of(target.id)
		local blueprint = if blueprint_id ~= nil then state.get(blueprint_id) else nil
		if blueprint ~= nil then
			if approach(entity, blueprint.position, work_range(entity, config.BUILD_RANGE) * RANGE_MARGIN) then
				construction.request(entity, blueprint)
			end
			return
		end

		local reclaimed_id = reclaim.recent_target_of(target.id)
		local reclaimed = if reclaimed_id ~= nil then state.get(reclaimed_id) else nil
		if reclaimed ~= nil and reclaim.can_reclaim(entity, reclaimed) then
			if approach(entity, reclaimed.position, work_range(entity, config.RECLAIM_RANGE) * RANGE_MARGIN) then
				reclaim.request(entity, reclaimed)
			end
			return
		end
	end

	-- Nothing to build or reclaim, so it keeps close to what it guards, and if it can repair and the
	-- guarded unit is hurt, it repairs it. That is what it does when it has nothing else on: while it is
	-- still catching up it is busy moving, and it repairs once it is settled beside it and in reach.
	local settled = true
	if is_immobile(entity) == false then
		local target_def = unit_defs.get(target.def_name)
		local gap = unit_defs.collider_radius(def) + unit_defs.collider_radius(target_def) + config.GUARD_FOLLOW_GAP
		settled = approach(entity, target.position, gap)
	end

	-- If settled and there are other orders queued, drop guard and do the queued work instead
	if settled and #entity.orders > 1 then
		pop(entity)
		return
	end

	local reach = work_range(entity, config.BUILD_RANGE) * RANGE_MARGIN
	if
		settled
		and def.repairing
		and def.buildpower ~= nil
		and target.state == "active"
		and target.health < target.max_health
		and geometry.distance_2d(entity.position, target.position) <= reach
	then
		construction.repair(entity, target, config.TICK_DELTA)
	end
end

-- The blueprint of `def_name` already standing at `position` on `team`, if any.
local function find_blueprint(team: types.TeamId, def_name: string, position: Vector3): Entity?
	local function matches(other: Entity): boolean
		return other.alive
			and other.state == "blueprint"
			and other.team == team
			and other.def_name == def_name
			and geometry.distance_2d(other.position, position) < 0.5
	end
	for _, other in state.all() do
		if matches(other) then
			return other
		end
	end
	for _, other in started_this_tick do
		if matches(other) then
			return other
		end
	end
	return nil
end

-- How a builder is getting on with the site it was sent to: the order, which stage it is at, the best it has
-- managed so far (its distance from the site, or how many things still stand on it) and how long it has
-- gone without beating that.
local build_waits: { [types.EntityId]: { order: Order, phase: string, best: number, stuck: number } } = {}
-- Less than this counts as no progress at all.
local PROGRESS_EPSILON = 0.25

-- Notes that a build order is at `phase` with `measure` (lower is better) and returns whether it has now gone
-- config.BUILD_STUCK_SECONDS with no improvement.
local function build_stuck(entity: Entity, order: Order, phase: string, measure: number): boolean
	local wait = build_waits[entity.id]
	if wait == nil or wait.order ~= order or wait.phase ~= phase then
		build_waits[entity.id] = { order = order, phase = phase, best = measure, stuck = 0 }
		return false
	end
	if measure < wait.best - PROGRESS_EPSILON then
		wait.best = measure
		wait.stuck = 0
	else
		wait.stuck += tick_delta
	end
	return wait.stuck >= config.BUILD_STUCK_SECONDS
end

local function drop_build(entity: Entity)
	build_waits[entity.id] = nil
	pop(entity)
end

-- Whether a unit has nothing to do: no orders, or only guarding something that has nothing to do either.
local function is_idle(unit: Entity, depth: number): boolean
	local first = unit.orders[1]
	if first == nil then
		return true
	end
	if first.kind == "guard" and depth < 4 then
		local guarded = if first.target_id ~= nil then state.get(first.target_id) else nil
		return guarded == nil or guarded.alive == false or is_idle(guarded, depth + 1)
	end
	return false
end

-- Where `unit` should go to be clear of a footprint at `center`: straight away from it, past its corners.
local function vacate_point(unit: Entity, center: Vector3, half: Vector2): Vector3
	local unit_def = unit_defs.get(unit.def_name)
	local reach = math.max(half.X, half.Y) * 1.5 + unit_defs.collider_radius(unit_def) + 4
	local away = geometry.flatten(unit.position - center)
	local direction = if away.Magnitude < 1e-3 then Vector3.new(1, 0, 0) else away.Unit
	local point = center + direction * reach
	if heightmap.in_bounds(point.X, point.Z) == false then
		point = center - direction * reach
	end
	return unit_defs.surface_position(unit_def, point.X, point.Z)
end

-- The builder is at its site but something stands on it. A wreck is reclaimed first, and idle units of its own
-- team are told to move off; anything else, or units that are busy, stay in the way. Ten seconds without
-- fewer things in the way and the order is dropped.
local function clear_site(entity: Entity, order: Order, def_name: string, position: Vector3, facing: number)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(unit_defs.get(def_name)), facing)
	local blockers = placement.overlapping(def_name, position, facing, entity.id)
	for _, other in blockers do
		if other.kind == "wreck" then
			if reclaim.can_reclaim(entity, other) then
				-- reclaim it first; the build order is still there under it when that is done
				table.insert(entity.orders, 1, { kind = "reclaim", position = nil, target_id = other.id })
				build_waits[entity.id] = nil
				return
			end
		elseif placement.clearable(other, entity.team) and is_idle(other, 0) then
			other.orders = {
				{ kind = "move", position = vacate_point(other, position, half), target_id = nil },
			}
		end
	end
	if build_stuck(entity, order, "site", #blockers) then
		drop_build(entity)
	end
end

-- Walks to the build site and, on arriving, puts the blueprint down and starts on it. Builders sent
-- to the same spot share the one blueprint, and if the spot has since been taken the order is
-- dropped.
local function run_build(entity: Entity, order: Order)
	local position = order.position
	local def_name = order.def_name
	local facing = order.facing
	local def = unit_defs.get(entity.def_name)
	if position == nil or def_name == nil or facing == nil or def.assisting == false or def.buildpower == nil then
		drop_build(entity)
		return
	end
	if approach(entity, position, work_range(entity, config.BUILD_RANGE) * RANGE_MARGIN) == false then
		if build_stuck(entity, order, "approach", geometry.distance_2d(entity.position, position)) then
			drop_build(entity)
		end
		return
	end

	local blueprint = find_blueprint(entity.team, def_name, position)
	if blueprint == nil then
		local placeable, reason = placement.can_place(def_name, position, facing, entity.id)
		if placeable == false then
			if reason == "blocked" then
				clear_site(entity, order, def_name, position, facing)
			else
				drop_build(entity)
			end
			return
		end
		blueprint = state.create_entity(def_name, entity.team, position, facing, "blueprint")
		table.insert(started_this_tick, blueprint)
	end

	-- from here it is an ordinary job of helping build that blueprint
	build_waits[entity.id] = nil
	entity.orders[1] = { kind = "assist", position = nil, target_id = blueprint.id }
	construction.request(entity, blueprint)
end

-- Loading: fly down to a unit or a static defence, friend or enemy, keep pace with it, and take it aboard the
-- moment the transport is touching it and still enough to hook it. The order ends once it is aboard, or when it
-- cannot be: the thing is gone, or was picked up by someone else, or there is no room for it.
local function run_load(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	if target == nil or transport.can_load(entity, target) == false then
		pop(entity)
		return
	end
	transport.reach_for(entity, target)
	if transport.in_grasp(entity, target) then
		transport.load(entity, target)
		pop(entity)
	end
end

-- Unloading: fly to the point and set everything it carries down around it.
local function run_unload(entity: Entity, order: Order)
	local position = order.position
	if position == nil or unit_defs.get(entity.def_name).transport == nil then
		pop(entity)
		return
	end
	if approach(entity, position, config.ARRIVAL_RADIUS) then
		transport.unload(entity, position)
		pop(entity)
	end
end

-- A building that builds, like a construction turret, cannot be ordered anywhere. It works on its
-- own, putting its buildpower into the nearest friendly blueprint within its reach, and failing that into the
-- nearest damaged unit or building of its own team or an ally.
local function run_static_builder(entity: Entity)
	local def = unit_defs.get(entity.def_name)
	local reach = def.build_range
	if def.assisting == false or def.buildpower == nil or reach == nil then
		return
	end

	local best: Entity? = nil
	local best_distance = reach
	for _, other in state.all() do
		if other.alive == false or other.state ~= "blueprint" or other.team ~= entity.team or other.id == entity.id then
			continue
		end
		local distance = geometry.distance_2d(entity.position, other.position)
		if distance <= best_distance then
			best = other
			best_distance = distance
		end
	end
	if best ~= nil then
		construction.request(entity, best)
		return
	end

	-- with nothing to build it repairs the nearest damaged unit or building in reach that is its own team's or an ally's
	if def.repairing == false then
		return
	end
	local hurt: Entity? = nil
	local hurt_distance = reach
	for _, other in state.all() do
		if
			other.alive == false
			or other.kind == "wreck"
			or other.state ~= "active"
			or alliances.are_allied(entity.team, other.team) == false
			or other.health >= other.max_health
			-- there is no point mending what someone is taking apart
			or reclaim.is_reclaimed_by_ally(other)
		then
			continue
		end
		local distance = geometry.distance_2d(entity.position, other.position)
		if distance <= hurt_distance then
			hurt = other
			hurt_distance = distance
		end
	end
	if hurt ~= nil then
		construction.repair(entity, hurt, config.TICK_DELTA)
		return
	end

	-- with nothing else to do it reclaims the nearest wreck in reach if it can
	if def.reclaiming ~= false then
		local wreck: Entity? = nil
		local wreck_distance = reach
		for _, other in state.all() do
			if other.alive == false or other.kind ~= "wreck" then
				continue
			end
			if reclaim.can_reclaim(entity, other) then
				local distance = geometry.distance_2d(entity.position, other.position)
				if distance <= wreck_distance then
					wreck = other
					wreck_distance = distance
				end
			end
		end
		if wreck ~= nil then
			reclaim.request(entity, wreck)
		end
	end
end

local function tick(delta: number)
	tick_delta = delta
	table.clear(started_this_tick)
	for _, entity in state.all() do
		-- a wreck keeps the def of what it was, but it takes no orders and does no work
		if entity.alive == false or entity.state ~= "active" or entity.kind == "wreck" then
			continue
		end
		if unit_defs.takes_orders(unit_defs.get(entity.def_name)) == false then
			continue
		end

		local order = entity.orders[1]
		-- an attack that has launched a stockpiled missile at its target is done: one order sends one missile
		local launched = combat.take_launch(entity.id)
		if launched and order ~= nil and (order.kind == "attack" or order.kind == "attack_ground") then
			combat.set_forced_target(entity, nil)
			pop(entity)
			order = entity.orders[1]
		end
		if order == nil then
			combat.set_forced_target(entity, nil)
			-- with nothing to do, a turret helps build what is near it
			run_static_builder(entity)
			continue
		end

		if order.kind == "move" then
			combat.set_forced_target(entity, nil)
			run_move(entity, order)
		elseif order.kind == "fight" then
			combat.set_forced_target(entity, nil)
			run_fight(entity, order)
		elseif order.kind == "attack" then
			run_attack(entity, order)
		elseif order.kind == "attack_ground" then
			run_attack_ground(entity, order)
		elseif order.kind == "dgun" then
			combat.set_forced_target(entity, nil)
			run_dgun(entity, order)
		elseif order.kind == "reclaim" then
			combat.set_forced_target(entity, nil)
			run_reclaim(entity, order)
		elseif order.kind == "resurrect" then
			combat.set_forced_target(entity, nil)
			run_resurrect(entity, order)
		elseif order.kind == "assist" then
			combat.set_forced_target(entity, nil)
			run_assist(entity, order)
		elseif order.kind == "guard" then
			combat.set_forced_target(entity, nil)
			run_guard(entity, order)
		elseif order.kind == "repair" then
			combat.set_forced_target(entity, nil)
			run_repair(entity, order)
		elseif order.kind == "build" then
			combat.set_forced_target(entity, nil)
			run_build(entity, order)
		elseif order.kind == "load" then
			combat.set_forced_target(entity, nil)
			run_load(entity, order)
		elseif order.kind == "unload" then
			combat.set_forced_target(entity, nil)
			run_unload(entity, order)
		else
			pop(entity)
		end
	end
end

return table.freeze({
	issue = issue,
	tick = tick,
})
