-- Order execution. Every tick each unit looks at the front of its queue, decides where it wants
-- to be, and registers whatever work that order implies. Orders are popped as they complete, so
-- an empty queue means idle.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

local state = require(script.Parent.state)
local movement = require(script.Parent.movement)
local combat = require(script.Parent.combat)
local reclaim = require(script.Parent.reclaim)
local resurrection = require(script.Parent.resurrection)
local construction = require(script.Parent.construction)
local placement = require(script.Parent.placement)
local transport = require(script.Parent.transport)
local alliances = require(script.Parent.alliances)
local campaign = require(script.Parent.campaign)
local orbits = require(script.Parent.orbits)

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
	return unit_defs.of(entity).max_speed == nil
end

-- How far `entity` reaches to work: its own reach if it has one, like a construction turret, or the
-- usual range for units.
local function work_range(entity: Entity, usual: number): number
	local reach = unit_defs.of(entity).build_range
	if reach ~= nil then
		return reach
	end
	return usual
end

-- The point of something of `def_name` standing at `center`, turned to `facing`, nearest to `from` on the ground: a
-- builder has what it works on in reach as soon as its reach touches any part of its collider, so it need not come
-- within reach of the middle of a big building. `from` itself when it is already inside.
local function nearest_point_of(def_name: string, center: Vector3, facing: number, from: Vector3): Vector3
	local collider = unit_defs.get(def_name).collider
	if collider.shape == "box" then
		local half = geometry.rotated_half_extents(Vector2.new(collider.width / 2, collider.length / 2), facing)
		return Vector3.new(
			math.clamp(from.X, center.X - half.X, center.X + half.X),
			center.Y,
			math.clamp(from.Z, center.Z - half.Y, center.Z + half.Y)
		)
	end
	return geometry.clamp_to_range(center, from, collider.radius)
end

-- The point of `target` nearest to `entity`, where its reach to it is measured (`nearest_point_of`).
local function nearest_point_on(entity: Entity, target: Entity): Vector3
	return nearest_point_of(target.def_name, target.position, target.facing, entity.position)
end

-- How close `entity` has to come to a point it is making for to count as there: `usual`, or for an aircraft on
-- wings, which cannot stop on a point and circles it instead, no closer than the circle it turns in.
local function arrival_radius(entity: Entity, usual: number): number
	return math.max(usual, unit_defs.turn_radius(unit_defs.of(entity)))
end

-- Walks toward `position`, stopping `stop_radius` short. Returns whether it is already there. Something
-- that cannot move stays where it is, so for it this only ever answers whether the target is in reach.
-- It goes straight: a way round a cliff or a lake is laid as move waypoints ahead of the order when it is given
-- (`commands`), where the player can see it, and never worked out here.
local function approach(entity: Entity, position: Vector3, stop_radius: number): boolean
	stop_radius = arrival_radius(entity, stop_radius)
	if geometry.distance_2d(entity.position, position) <= stop_radius then
		return true
	end
	if is_immobile(entity) == false then
		movement.set_goal(entity, position, stop_radius, false)
	end
	return false
end

-- How far out of its middle something of `def_name` reaches whichever way, at the least: its nearest point is never
-- further in than this, so a spot this much further out than a builder's reach to that point is still in its reach.
local function inner_extent(def_name: string): number
	local collider = unit_defs.get(def_name).collider
	if collider.shape == "box" then
		return math.min(collider.width, collider.length) / 2
	end
	return collider.radius
end

-- For an aircraft that hovers and has `target` in reach, `reach` beyond `extent` from its middle: rather than stop
-- where it is, it flies to its spot in the ring round it, which it moves every few seconds (`orbits`). Anything else
-- stays where it is.
local function orbit(entity: Entity, target: Entity, role: orbits.Role, extent: number, reach: number)
	if orbits.orbits(unit_defs.of(entity)) == false then
		return
	end
	local point = orbits.station_point(
		entity,
		target,
		role,
		extent + reach * config.ORBIT_INNER,
		extent + reach * config.ORBIT_OUTER,
		tick_delta
	)
	movement.set_goal(entity, point, config.ARRIVAL_RADIUS, false)
end

-- Walks a chain of move orders, a route's or the waypoints a player laid. A waypoint with another after it is closed
-- in on as near as `config.WAYPOINT_EPSILON`, slowing to get there, and from `config.WAYPOINT_SKIP_RANGE` out the unit
-- checks whether it can already go straight to the next; as soon as it can it does, so it never cuts a corner it
-- cannot see round. One that is right on its waypoint goes on to the next whether it can see it or not. An aircraft counts as on its waypoint within the circle it turns in.
-- Moving on to the next order within the same tick matters as much as not braking: goals are cleared
-- every tick, so popping an order and leaving the next for the following tick would drop the unit's
-- goal for a tick at each waypoint, and it would coast.
-- Whether `entity`, making for the waypoint at `position` with another at `following` after it, is done with it: it is
-- right on it, or near enough to check and can already go straight on to the next. Until it is, it closes in.
local function passes_waypoint(entity: Entity, position: Vector3, following: Vector3): boolean
	local def = unit_defs.of(entity)
	local distance = geometry.distance_2d(entity.position, position)
	if distance <= arrival_radius(entity, config.WAYPOINT_EPSILON) then
		return true
	end
	if distance > arrival_radius(entity, config.WAYPOINT_SKIP_RANGE) then
		return false
	end
	return def.air ~= nil or pathfinder.has_straight_path(def, entity.position, following)
end

local function run_move(entity: Entity, first: Order)
	local order = first

	for _ = 1, #entity.orders do
		local position = order.position
		if position == nil or is_immobile(entity) then
			pop(entity)
		else
			local following = entity.orders[2]
			if following ~= nil and following.kind == "move" and following.position ~= nil then
				if passes_waypoint(entity, position, following.position) == false then
					movement.set_goal(entity, position, arrival_radius(entity, config.WAYPOINT_EPSILON), false)
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
-- would come down on as it goes (`combat` does that, letting them go short of what they are for, since they
-- carry on at its speed as they fall). Once it has flown over the point it holds its heading until it is its
-- run-out clear of it, and only then turns back for another pass (`movement` does that for anything on wings).
local function run_bombing(entity: Entity, point: Vector3)
	movement.set_goal(entity, point, config.ARRIVAL_RADIUS, true)
end

-- Puts `entity`'s buildpower into the nearest thing within `reach` it can work on, and returns whether it found one:
-- the nearest blueprint of its own team or an ally's if it can assist, failing that the nearest damaged unit or
-- building of its own team or an ally's if it can repair, and failing that the nearest wreck or reclaimable if it can
-- reclaim and `reclaims` is set.
-- It is what a construction turret does all the time and what a builder on a fight order stops along the way to do.
local function work_nearby(entity: Entity, reach: number, reclaims: boolean): boolean
	local def = unit_defs.of(entity)
	if def.buildpower == nil then
		return false
	end

	if def.assisting then
		local best: Entity? = nil
		local best_distance = reach
		for _, other in state.all() do
			if
				other.alive == false
				or other.state ~= "blueprint"
				or alliances.are_allied(entity.team, other.team) == false
				or other.id == entity.id
			then
				continue
			end
			local distance = geometry.distance_2d(entity.position, nearest_point_on(entity, other))
			if distance <= best_distance then
				best = other
				best_distance = distance
			end
		end
		if best ~= nil then
			construction.request(entity, best)
			return true
		end
	end

	if def.repairing then
		local hurt: Entity? = nil
		local hurt_distance = reach
		for _, other in state.all() do
			if
				other.alive == false
				or other.id == entity.id
				or other.kind == "wreck"
				or other.state ~= "active"
				or alliances.are_allied(entity.team, other.team) == false
				or other.health >= other.max_health
				-- there is no point mending what someone is taking apart
				or reclaim.is_reclaimed_by_ally(other)
			then
				continue
			end
			local distance = geometry.distance_2d(entity.position, nearest_point_on(entity, other))
			if distance <= hurt_distance then
				hurt = other
				hurt_distance = distance
			end
		end
		if hurt ~= nil then
			construction.repair(entity, hurt, config.TICK_DELTA)
			return true
		end
	end

	if def.reclaiming and reclaims then
		local remains: Entity? = nil
		local remains_distance = reach
		for _, other in state.all() do
			if other.alive == false or (other.kind ~= "wreck" and other.kind ~= "reclaimable") then
				continue
			end
			local distance = geometry.distance_2d(entity.position, other.position)
			if distance <= remains_distance and reclaim.can_reclaim(entity, other) then
				remains = other
				remains_distance = distance
			end
		end
		if remains ~= nil then
			reclaim.request(entity, remains)
			return true
		end
	end
	return false
end

-- Fighting: walk to the point the way a move does, but whenever there is something to shoot at, stand still
-- and shoot it (`combat` picks what and does the shooting, as it does for anything with no target
-- ordered), and set off again once there is nothing left. A builder stops the same way for work within its
-- reach: a blueprint to help build, something of its side's to repair, or a wreck or reclaimable to reclaim, whichever of
-- them it can do. The order ends on arrival. A unit that can do neither has nothing to stop for, and neither
-- has a bomber, which cannot stop, so for them it is a move.
--
-- A fight is given as a chain of fight waypoints along the route to the point, as a move is given its route (see
-- `commands`), and walked the way a move's are (`passes_waypoint`), so it fights its way along all of them; the
-- stopping comes first, wherever along the chain it is.
local function run_fight(entity: Entity, first: Order)
	if first.position == nil or is_immobile(entity) then
		pop(entity)
		return
	end

	local def = unit_defs.of(entity)
	if unit_defs.attack_range(def) ~= nil and is_bomber(def) == false and combat.has_target(entity) then
		return
	end
	if work_nearby(entity, work_range(entity, config.BUILD_RANGE) * RANGE_MARGIN, true) then
		return
	end

	local order = first
	for _ = 1, #entity.orders do
		local position = order.position
		if position == nil then
			pop(entity)
		else
			local following = entity.orders[2]
			if following ~= nil and following.kind == "fight" and following.position ~= nil then
				if passes_waypoint(entity, position, following.position) == false then
					movement.set_goal(entity, position, arrival_radius(entity, config.WAYPOINT_EPSILON), false)
					return
				end
				pop(entity)
			else
				-- the last waypoint: arriving on it ends the fight
				if approach(entity, position, config.ARRIVAL_RADIUS) then
					pop(entity)
				end
				return
			end
		end

		local next_order = entity.orders[1]
		if next_order == nil or next_order.kind ~= "fight" then
			return
		end
		order = next_order
	end
end

-- Whether some weapon of `def` could be turned on `target` at all: true for an unarmed def too, since
-- nothing about its (nonexistent) weapons rules the order out on its own.
local function any_weapon_can_target(def: types.EntityDef, target: Entity): boolean
	if def.weapons == nil then
		return true
	end
	for _, weapon in def.weapons do
		if combat.can_target(weapon, target) then
			return true
		end
	end
	return false
end

-- Whether every weapon of `def` only shoots at aircraft, so it never has a shot at the ground.
local function all_weapons_air_only(def: types.EntityDef): boolean
	if def.weapons == nil then
		return false
	end
	for _, weapon in def.weapons do
		if weapon.target_layer ~= "air" then
			return false
		end
	end
	return true
end

-- How far the longest of `def`'s weapons that can shoot at `target` reaches, or nil if it has no weapons at all. One
-- none of whose weapons can be turned on it (which `run_attack` has already ruled out) gets its longest reach.
local function reach_against(def: types.EntityDef, target: Entity): number?
	local longest: number? = nil
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			if combat.can_target(weapon, target) and (longest == nil or weapon.range > longest) then
				longest = weapon.range
			end
		end
	end
	if longest == nil then
		return unit_defs.attack_range(def)
	end
	return longest
end

local function run_attack(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	local def = unit_defs.of(entity)
	if target == nil or combat.is_valid_forced_target(entity, target) == false then
		combat.set_forced_target(entity, nil)
		pop(entity)
		return
	end
	-- an order to shoot at something none of its weapons can be turned on, like a fighter told to
	-- attack a tank, is no order at all
	if any_weapon_can_target(def, target) == false then
		combat.set_forced_target(entity, nil)
		pop(entity)
		return
	end

	combat.set_forced_target(entity, target.id)

	-- a unit with turrets is armed too, and closes in on what its longest one that can shoot at the target reaches:
	-- a gunship's anti air missiles reach further than its guns, but the guns are what a tank is attacked with
	local reach = reach_against(def, target)
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
	-- a building cannot move out of reach, so it is shot from wherever it already can be: from high ground a shell
	-- reaches further than its range on the level, and walking on in to well within range, off the high ground or
	-- into the building's own reach, is only for what might move off
	if target.kind == "building" and combat.can_shoot(entity, target) then
		return
	end
	-- in range is not enough: something behind a hill cannot be shot, so it walks on until it can see it, as far as
	-- touching it, and no further, so that it never presses into a building it cannot see over
	if approach(entity, target.position, reach * RANGE_MARGIN) then
		if combat.can_shoot(entity, target) == false then
			local touching = unit_defs.collider_radius(def) + unit_defs.collider_radius(unit_defs.of(target))
			approach(entity, target.position, touching)
		else
			-- a gunship keeps circling it as it fires
			orbit(entity, target, "gunship", 0, reach)
		end
	end
end

-- Attacking the ground: close in until the point is in range, then keep shooting at it. Nothing ends the
-- order but another one, since there is no target to run out of; only a unit that cannot shoot drops it,
-- or one whose weapon only shoots at aircraft.
local function run_attack_ground(entity: Entity, order: Order)
	local position = order.position
	local def = unit_defs.of(entity)
	local reach = unit_defs.attack_range(def)
	if position == nil or reach == nil or all_weapons_air_only(def) then
		combat.set_forced_target(entity, nil)
		pop(entity)
		return
	end

	combat.set_forced_ground(entity, position)
	if is_bomber(def) then
		run_bombing(entity, position)
		return
	end
	-- the ground goes nowhere, so as with a building it is shot from wherever it already can be; otherwise, as an
	-- attack does, it walks on past being in range until it has a clear shot
	if combat.can_shoot_point(entity, position) then
		return
	end
	if approach(entity, position, reach * RANGE_MARGIN) and combat.can_shoot_point(entity, position) == false then
		approach(entity, position, config.ARRIVAL_RADIUS)
	end
end

-- The commander's disintegrator at a point: close in until the point is within the weapon's range, then fire
-- as soon as it is ready and that is the order done. A weapon that is still reloading, or a team that is short
-- of the energy for it, is waited for, but a shot that an enemy commander is in the way of is dropped, since
-- nothing is going to change that. A unit with no manual weapon drops it.
local function run_dgun(entity: Entity, order: Order)
	local position = order.position
	local weapon = unit_defs.of(entity).manual_weapon
	if position == nil or weapon == nil then
		pop(entity)
		return
	end
	-- It walks in to well within range, but fires as soon as the spot is in range at all: the shot sweeps all the way
	-- to its range, so it reaches the spot from there, and something big standing on the spot (the tutorial's boulder)
	-- can keep it from getting any closer.
	if
		geometry.distance_2d(entity.position, position) > weapon.range
		and approach(entity, position, weapon.range * RANGE_MARGIN) == false
	then
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
	local reach = work_range(entity, config.RECLAIM_RANGE)
	if approach(entity, target.position, reach * RANGE_MARGIN) then
		reclaim.request(entity, target)
		orbit(entity, target, "build", 0, reach)
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
	local reach = work_range(entity, config.RESURRECT_RANGE)
	if approach(entity, target.position, reach * RANGE_MARGIN) then
		resurrection.request(entity, target)
		orbit(entity, target, "build", 0, reach)
	elseif is_immobile(entity) then
		pop(entity)
	end
end

local function run_assist(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	if target == nil or target.state ~= "blueprint" or alliances.are_allied(entity.team, target.team) == false then
		pop(entity)
		return
	end
	local def = unit_defs.of(entity)
	if def.assisting == false or def.buildpower == nil then
		pop(entity)
		return
	end
	local reach = work_range(entity, config.BUILD_RANGE)
	if approach(entity, nearest_point_on(entity, target), reach * RANGE_MARGIN) then
		construction.request(entity, target)
		orbit(entity, target, "build", inner_extent(target.def_name), reach)
	elseif is_immobile(entity) then
		pop(entity)
	end
end

-- Repairing: walk up to a damaged friendly, or an ally's, and restore its health until it is whole. The order ends
-- when the target is full, gone, or no longer something that can be repaired.
local function run_repair(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	local def = unit_defs.of(entity)
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
	local reach = work_range(entity, config.BUILD_RANGE)
	if approach(entity, nearest_point_on(entity, target), reach * RANGE_MARGIN) then
		construction.repair(entity, target, config.TICK_DELTA)
		orbit(entity, target, "build", inner_extent(target.def_name), reach)
	elseif is_immobile(entity) then
		pop(entity)
	end
end

-- An area command: reclaim, repair, resurrect or attack everything of the right kind within a circle,
-- one thing at a time. Each tick it looks for the nearest valid thing left in the circle and pushes a
-- single-target order in front of itself to go and do it; when that finishes, this order is back at the
-- front and looks again. It is done, and pops itself, once nothing is left in the circle to do.
local function run_area(entity: Entity, order: Order, kind: types.OrderKind, find: (Entity, Vector3, number) -> Entity?)
	local center = order.position
	local radius = order.radius
	if center == nil or radius == nil then
		pop(entity)
		return
	end
	local target = find(entity, center, radius)
	if target == nil then
		pop(entity)
		return
	end
	table.insert(entity.orders, 1, { kind = kind, position = nil, target_id = target.id })
end

local function nearest_in_radius(entity: Entity, center: Vector3, radius: number, matches: (Entity) -> boolean): Entity?
	local best: Entity? = nil
	local best_distance = math.huge
	for _, other in state.all() do
		if geometry.distance_2d(other.position, center) > radius or matches(other) == false then
			continue
		end
		local distance = geometry.distance_2d(entity.position, other.position)
		if distance < best_distance then
			best = other
			best_distance = distance
		end
	end
	return best
end

local function run_area_reclaim(entity: Entity, order: Order)
	local def = unit_defs.of(entity)
	if def.reclaiming == false or def.buildpower == nil then
		pop(entity)
		return
	end
	run_area(entity, order, "reclaim", function(who, center, radius)
		return nearest_in_radius(who, center, radius, function(other)
			return other.alive
				and (other.kind == "wreck" or other.kind == "reclaimable")
				and reclaim.can_reclaim(who, other)
		end)
	end)
end

local function run_area_repair(entity: Entity, order: Order)
	local def = unit_defs.of(entity)
	if def.repairing == false or def.buildpower == nil then
		pop(entity)
		return
	end
	run_area(entity, order, "repair", function(who, center, radius)
		return nearest_in_radius(who, center, radius, function(other)
			return other.alive
				and other.id ~= who.id
				and other.kind ~= "wreck"
				and other.state == "active"
				and alliances.are_allied(who.team, other.team)
				and other.health < other.max_health
				and reclaim.is_reclaimed_by_ally(other) == false
		end)
	end)
end

local function run_area_resurrect(entity: Entity, order: Order)
	local def = unit_defs.of(entity)
	if def.resurrecting == false or def.buildpower == nil then
		pop(entity)
		return
	end
	run_area(entity, order, "resurrect", function(who, center, radius)
		return nearest_in_radius(who, center, radius, function(other)
			return other.alive and other.kind == "wreck" and resurrection.can_resurrect(who, other)
		end)
	end)
end

local function run_area_attack(entity: Entity, order: Order)
	local def = unit_defs.of(entity)
	run_area(entity, order, "attack", function(who, center, radius)
		return nearest_in_radius(who, center, radius, function(other)
			return combat.is_enemy(who, other) and any_weapon_can_target(def, other)
		end)
	end)
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

	local def = unit_defs.of(entity)
	if def.assisting and def.buildpower ~= nil then
		local blueprint_id = construction.recent_target_of(target.id)
		local blueprint = if blueprint_id ~= nil then state.get(blueprint_id) else nil
		if blueprint ~= nil then
			local reach = work_range(entity, config.BUILD_RANGE) * RANGE_MARGIN
			if approach(entity, nearest_point_on(entity, blueprint), reach) then
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
		local target_def = unit_defs.of(target)
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
		and geometry.distance_2d(entity.position, nearest_point_on(entity, target)) <= reach
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
	local unit_def = unit_defs.of(unit)
	local reach = math.max(half.X, half.Y) * 1.5 + unit_defs.collider_radius(unit_def) + 4
	local away = geometry.flatten(unit.position - center)
	local direction = if away.Magnitude < 1e-3 then Vector3.new(1, 0, 0) else away.Unit
	local point = center + direction * reach
	if heightmap.in_bounds(point.X, point.Z) == false then
		point = center - direction * reach
	end
	return unit_defs.surface_position(unit_def, point.X, point.Z)
end

-- The builder is at its site but something stands on it. A wreck or reclaimable is reclaimed first, and idle units of its own
-- team are told to move off; anything else, or units that are busy, stay in the way. Ten seconds without
-- fewer things in the way and the order is dropped.
local function clear_site(entity: Entity, order: Order, def_name: string, position: Vector3, facing: number)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(unit_defs.get(def_name)), facing)
	local blockers = placement.overlapping(def_name, position, facing, entity.id)
	for _, other in blockers do
		if other.kind == "wreck" or other.kind == "reclaimable" then
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
	local def = unit_defs.of(entity)
	if position == nil or def_name == nil or facing == nil or def.assisting == false or def.buildpower == nil then
		drop_build(entity)
		return
	end
	-- nothing its team has not unlocked in the campaign, even if it was ordered while it had
	if campaign.can_build(entity.team, def_name) == false then
		drop_build(entity)
		return
	end
	local nearest = nearest_point_of(def_name, position, facing, entity.position)
	if approach(entity, nearest, work_range(entity, config.BUILD_RANGE) * RANGE_MARGIN) == false then
		if build_stuck(entity, order, "approach", geometry.distance_2d(entity.position, nearest)) then
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

-- Unloading: fly to the point, come down until what it carries is just off the ground, and set it all down
-- around it.
local function run_unload(entity: Entity, order: Order)
	local position = order.position
	if position == nil or unit_defs.of(entity).transport == nil then
		pop(entity)
		return
	end
	if approach(entity, position, config.ARRIVAL_RADIUS) and transport.lower(entity) then
		transport.unload(entity, position)
		pop(entity)
	end
end

-- A building that builds, like a construction turret, cannot be ordered anywhere. It works on its
-- own, on whatever is nearest within its reach (`work_nearby`). An idle builder with a reach of its own that can move
-- helps build and repair the same way, but reclaims only when told to, so it does not eat the map around it.
local function run_static_builder(entity: Entity)
	local reach = unit_defs.of(entity).build_range
	if reach ~= nil then
		work_nearby(entity, reach, is_immobile(entity))
	end
end

local function tick(delta: number)
	tick_delta = delta
	table.clear(started_this_tick)
	orbits.begin_tick()
	for _, entity in state.all() do
		-- a wreck keeps the def of what it was, but it takes no orders and does no work, and nor does a reclaimable
		if
			entity.alive == false
			or entity.state ~= "active"
			or entity.kind == "wreck"
			or entity.kind == "reclaimable"
		then
			continue
		end
		if unit_defs.takes_orders(unit_defs.of(entity)) == false then
			continue
		end
		-- a lab's orders are for the units it makes, which each take a copy (see production's rally_order)
		if unit_defs.is_factory(unit_defs.of(entity)) then
			continue
		end
		-- one on its way out of the lab that made it does nothing else until it is out: production drives it,
		-- and its orders wait
		if movement.exiting_from(entity.id) ~= nil then
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
		elseif order.kind == "area_reclaim" then
			combat.set_forced_target(entity, nil)
			run_area_reclaim(entity, order)
		elseif order.kind == "area_repair" then
			combat.set_forced_target(entity, nil)
			run_area_repair(entity, order)
		elseif order.kind == "area_resurrect" then
			combat.set_forced_target(entity, nil)
			run_area_resurrect(entity, order)
		elseif order.kind == "area_attack" then
			run_area_attack(entity, order)
		else
			pop(entity)
		end
	end
end

return table.freeze({
	issue = issue,
	tick = tick,
})
