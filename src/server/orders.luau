-- Order execution. Every tick each unit looks at the front of its queue, decides where it wants
-- to be, and registers whatever work that order implies. Orders are popped as they complete, so
-- an empty queue means idle.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

local state = require(script.Parent.state)
local movement = require(script.Parent.movement)
local attack_orders = require(script.Parent.attack_orders)
local manual_weapons = require(script.Parent.manual_weapons)
local shot_rules = require(script.Parent.shot_rules)
local targeting = require(script.Parent.targeting)
local reclaim = require(script.Parent.reclaim)
local resurrection = require(script.Parent.resurrection)
local construction = require(script.Parent.construction)
local work = require(script.Parent.work)
local placement = require(script.Parent.placement)
local transport = require(script.Parent.transport)
local alliances = require(script.Parent.alliances)
local spatial = require(script.Parent.spatial)
local build_rules = require(script.Parent.build_rules)
local orbits = require(script.Parent.orbits)
local control = require(script.Parent.control)
local sight = require(script.Parent.sight)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type Order = types.Order

local RANGE_MARGIN = order_kinds.RANGE_MARGIN

-- The length of the tick being run, for timing how long a builder has been stuck.
local tick_delta = 0
-- How long, in seconds, a unit is held up at the edge of ground it cannot stand on (a building, most often one put
-- down across its way after its route was laid, or a cliff) before it looks for a way round from where it is.
local REROUTE_AFTER = 1.5
-- How much longer it waits before looking again, held up still, when there was no way round.
local REROUTE_RETRY = 6
-- Waypoints on the way somewhere, a route's or a chain of moves', are closed in on as near as WAYPOINT_EPSILON,
-- slowing to do it. From WAYPOINT_SKIP_RANGE out a unit checks whether it can already walk straight to the next one,
-- and goes on to it as soon as it can, so it never cuts a corner it cannot see round. Within WAYPOINT_NEAR_SKIP_RANGE
-- the way to the next need only be open, as a route's own legs are, not roomy, so two units shouldering each other
-- over the same point, each on its way somewhere else, do not hold one another off it.
local WAYPOINT_EPSILON = 0.25
local WAYPOINT_SKIP_RANGE = 8
local WAYPOINT_NEAR_SKIP_RANGE = 3
-- How far outside the two colliders a guarding unit keeps from what it follows.
local GUARD_FOLLOW_GAP = 4
-- A builder that gets no closer to its build site, or no nearer to a clear footprint, for this many seconds
-- drops the order and goes on to the next.
local BUILD_STUCK_SECONDS = 10
-- How near a blueprint's middle has to be to a build order's spot to be the one it builds: only float error apart, as
-- builders sent to the same spot put it at exactly the same place.
local BLUEPRINT_MATCH_RADIUS = 0.5
-- How far down a chain of guards (one guarding one guarding another) a unit is looked through for being idle, so that
-- guards guarding each other in a ring do not look at each other for ever.
local GUARD_CHAIN_DEPTH = 4
-- How far clear of the corners of a footprint a unit sent off it goes (`vacate`).
local VACATE_GAP = 4
-- For a unit whose last look found no way round: how long it had been held up when it looked. It looks again only once
-- it has been held up REROUTE_RETRY longer than that, and forgets it once it is not held up at all.
local looked_in_vain: { [types.EntityId]: number } = {}

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

-- Sends `entity` to `point`: instead of everything it was doing, or with `front`, ahead of it, which it goes back to
-- once it is there.
local function push_move(entity: Entity, point: Vector3, front: boolean)
	issue(entity, { { kind = "move", position = point, target_id = nil } }, false, front)
end

local function is_immobile(entity: Entity): boolean
	return unit_defs.moves(entity.def) == false
end

-- How far `entity` reaches to work: its own reach if it has one, like a construction turret, or the
-- usual range for units.
local function work_range(entity: Entity, usual: number): number
	local reach = unit_defs.build_range(entity.def)
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
	return math.max(usual, unit_defs.turn_radius(entity.def))
end

-- For `entity`, held up at the edge of ground it cannot stand on for REROUTE_AFTER on its way to within `reach` of
-- `destination`: the moves that take it round from where it is, up to the first that is in reach, or none when it is
-- already as near as it can get, when it does not look again for REROUTE_RETRY. Nil when it has not been held up long
-- enough to look.
local function reroute(entity: Entity, destination: Vector3, reach: number): { Order }?
	local held = movement.held_for(entity.id)
	local in_vain = looked_in_vain[entity.id]
	if in_vain ~= nil and held < in_vain then
		-- it got off the ground that held it up since, and is held up afresh
		looked_in_vain[entity.id] = nil
		in_vain = nil
	end
	if held < (if in_vain ~= nil then in_vain + REROUTE_RETRY else 0) + REROUTE_AFTER then
		return nil
	end
	local moves = pathfinder.find_path(entity.def, entity.position, destination, pathfinder.MAX_EXPANSIONS).orders
	while #moves > 1 and geometry.distance_2d(moves[#moves - 1].position :: Vector3, destination) <= reach do
		table.remove(moves)
	end
	local last = moves[#moves]
	if last == nil or geometry.distance_2d(last.position :: Vector3, entity.position) <= world_scale.CELL_STUDS then
		looked_in_vain[entity.id] = held
		return {}
	end
	looked_in_vain[entity.id] = nil
	movement.clear_held(entity.id)
	return moves
end

-- Walks toward `position`, stopping `stop_radius` short. Returns whether it is already there. Something
-- that cannot move stays where it is, so for it this only ever answers whether the target is in reach.
-- It goes straight: a way round a cliff or a lake is laid as move waypoints ahead of the order when it is given
-- (`commands`), where the player can see it. Only one held up on the way, by a building put down since or ground
-- its waypoints did not see, finds its way round from where it is (`reroute`), as moves ahead of its order.
local function approach(entity: Entity, position: Vector3, stop_radius: number): boolean
	stop_radius = arrival_radius(entity, stop_radius)
	if geometry.distance_2d(entity.position, position) <= stop_radius then
		return true
	end
	if is_immobile(entity) == false then
		local route = if #entity.orders > 0 then reroute(entity, position, stop_radius) else nil
		if route ~= nil and #route > 0 then
			issue(entity, route, false, true)
			position = route[1].position :: Vector3
			stop_radius = arrival_radius(entity, WAYPOINT_EPSILON)
		end
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
	if orbits.orbits(entity.def) == false then
		return
	end
	local point = orbits.station_point(
		entity,
		target,
		role,
		extent + reach * orbits.ORBIT_INNER,
		extent + reach * orbits.ORBIT_OUTER,
		tick_delta
	)
	movement.set_goal(entity, point, movement.ARRIVAL_RADIUS, false)
end

-- Whether `entity`, making for the waypoint at `position` with another at `following` after it, is done with it: it is
-- right on it, or near enough to check and can already go straight on to the next (within WAYPOINT_NEAR_SKIP_RANGE, an
-- open way will do, one without room to spare). Until it is, it closes in. An aircraft counts as on its waypoint within
-- the circle it turns in.
local function passes_waypoint(entity: Entity, position: Vector3, following: Vector3): boolean
	local def = entity.def
	local distance = geometry.distance_2d(entity.position, position)
	if distance <= arrival_radius(entity, WAYPOINT_EPSILON) then
		return true
	end
	if distance > arrival_radius(entity, WAYPOINT_SKIP_RANGE) then
		return false
	end
	if def.air ~= nil or pathfinder.has_straight_path(def, entity.position, following) then
		return true
	end
	return distance <= WAYPOINT_NEAR_SKIP_RANGE and pathfinder.has_open_line(def, entity.position, following)
end

-- Walks the chain of `kind` orders at the front of `entity`'s queue, a route's or the waypoints a player laid, going
-- through at most `steps` of them this tick. A waypoint with another after it is closed in on as near as
-- `WAYPOINT_EPSILON`, slowing to get there, and from `WAYPOINT_SKIP_RANGE` out the unit checks whether it
-- can already go straight to the next (`passes_waypoint`); as soon as it can it does, so it never cuts a corner it
-- cannot see round. The last it stops on, which ends the chain.
-- Moving on to the next order within the same tick matters as much as not braking: goals are cleared every tick, so
-- popping an order and leaving the next for the following tick would drop the unit's goal for a tick at each waypoint,
-- and it would coast.
local function walk_chain(entity: Entity, kind: types.OrderKind, steps: number)
	for _ = 1, steps do
		local position = entity.orders[1].position
		if position == nil then
			pop(entity)
		else
			local following = entity.orders[2]
			if following ~= nil and following.kind == kind and following.position ~= nil then
				if passes_waypoint(entity, position, following.position) == false then
					movement.set_goal(entity, position, arrival_radius(entity, WAYPOINT_EPSILON), false)
					return
				end
				pop(entity)
			else
				if approach(entity, position, movement.ARRIVAL_RADIUS) then
					pop(entity)
				end
				return
			end
		end
		local next_order = entity.orders[1]
		if next_order == nil or next_order.kind ~= kind then
			return
		end
	end
end

-- Whether the order at the front of `entity`'s queue is a move.
local function moving(entity: Entity): boolean
	local front = entity.orders[1]
	return front ~= nil and front.kind == "move"
end

-- A move: a chain of moves walked (`walk_chain`). Something that cannot move is done with every move at once. One held
-- up on the way has the chain's moves replaced by a way round to where the last of them goes, or, when it is as near
-- to that as it can get, is done with them (`reroute`).
local function run_move(entity: Entity, _order: Order)
	if is_immobile(entity) then
		while moving(entity) do
			pop(entity)
		end
		return
	end
	local steps = #entity.orders
	while moving(entity) and entity.orders[1].position == nil do
		pop(entity)
		steps -= 1
	end
	if moving(entity) == false then
		return
	end
	local chain = 1
	while
		entity.orders[chain + 1] ~= nil
		and entity.orders[chain + 1].kind == "move"
		and entity.orders[chain + 1].position ~= nil
	do
		chain += 1
	end
	local route = reroute(entity, entity.orders[chain].position :: Vector3, 0)
	if route ~= nil then
		for _ = 1, chain do
			pop(entity)
		end
		issue(entity, route, false, true)
		if moving(entity) == false then
			return
		end
	end
	walk_chain(entity, "move", steps)
end

-- Whether it is the kind of aircraft that attacks by flying over what it attacks, and not by stopping to
-- hover in range of it.
local function is_bomber(def: types.EntityDef): boolean
	return def.air ~= nil and def.air.bombing_runs == true
end

-- A bombing run: it flies at `point` at full speed, over it and on past, and drops bombs on whatever it
-- would come down on as it goes (`weapons` does that, letting them go short of what they are for, since they
-- carry on at its speed as they fall). Once it has flown over the point it holds its heading until it is its
-- run-out clear of it, and only then turns back for another pass (`movement` does that for anything on wings).
local function run_bombing(entity: Entity, point: Vector3)
	movement.set_goal(entity, point, movement.ARRIVAL_RADIUS, true)
end

-- Puts `entity`'s buildpower into the nearest thing within `reach` it can work on, and returns whether it found one:
-- the nearest blueprint of its own team or an ally's if it can assist, failing that the nearest damaged unit or
-- building of its own team or an ally's if it can repair, and failing that the nearest wreck or reclaimable if it can
-- reclaim and `reclaims` is set.
-- It is what a construction turret does all the time and what a builder on a fight order stops along the way to do.
local function work_nearby(entity: Entity, reach: number, reclaims: boolean): boolean
	local def = entity.def
	if def.builder == nil then
		return false
	end

	if unit_defs.does(def, "assist") then
		local best: Entity? = nil
		local best_distance = reach
		spatial.each_near(entity.position.X, entity.position.Z, reach, function(other: Entity)
			if
				other.state ~= "blueprint"
				or alliances.are_allied(entity.team, other.team) == false
				or other.id == entity.id
			then
				return
			end
			local distance = geometry.distance_2d(entity.position, nearest_point_on(entity, other))
			if distance <= best_distance then
				best = other
				best_distance = distance
			end
		end)
		if best ~= nil then
			construction.request(entity, best)
			return true
		end
	end

	if unit_defs.does(def, "repair") then
		local hurt: Entity? = nil
		local hurt_distance = reach
		spatial.each_near(entity.position.X, entity.position.Z, reach, function(other: Entity)
			if construction.can_repair(entity, other) == false then
				return
			end
			local distance = geometry.distance_2d(entity.position, nearest_point_on(entity, other))
			if distance <= hurt_distance then
				hurt = other
				hurt_distance = distance
			end
		end)
		if hurt ~= nil then
			construction.repair(entity, hurt)
			return true
		end
	end

	if unit_defs.does(def, "reclaim") and reclaims then
		local remains: Entity? = nil
		local remains_distance = reach
		spatial.each_near(entity.position.X, entity.position.Z, reach, function(other: Entity)
			if unit_defs.is_remains(other.def) == false then
				return
			end
			local distance = geometry.distance_2d(entity.position, other.position)
			if distance <= remains_distance and reclaim.can_reclaim(entity, other) then
				remains = other
				remains_distance = distance
			end
		end)
		if remains ~= nil then
			reclaim.request(entity, remains)
			return true
		end
	end
	return false
end

-- Fighting: walk to the point the way a move does, but whenever there is something to shoot at, stand still
-- and shoot it (`targeting` picks what and `weapons` does the shooting, as it does for anything with no target
-- ordered), and set off again once there is nothing left. Something in reach that a friend is in the way of counts:
-- the unit waits behind the friend for a clear shot rather than pushing it on into the enemy's reach. A builder
-- stops the same way for work within its reach: a blueprint to help build, something of its side's to repair, or a wreck or reclaimable to reclaim, whichever of
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

	local def = entity.def
	if unit_defs.attack_range(def) ~= nil and is_bomber(def) == false and targeting.has_target(entity, true) then
		return
	end
	if work_nearby(entity, work_range(entity, order_kinds.BUILD_RANGE) * RANGE_MARGIN, true) then
		return
	end

	walk_chain(entity, "fight", #entity.orders)
end

-- Whether `entity` could be ordered to attack `aim`: it is unarmed, and would only walk onto it, or some weapon of its
-- can be turned on it at all (`shot_rules.reach_against`).
local function can_attack(entity: Entity, aim: sight.Aim): boolean
	return entity.def.weapons == nil or shot_rules.reach_against(entity.def, aim) ~= nil
end

-- What an attack order names, if it is there to be shot at: a target that is still there and an enemy or a wreck
-- (`targeting.is_valid_forced_target`), or for an attack on the ground the point.
local function aim_of(entity: Entity, order: Order): sight.Aim?
	if order.kind == "attack_ground" then
		return order.position
	end
	local target = if order.target_id ~= nil then state.get(order.target_id, true) else nil
	if target == nil or targeting.is_valid_forced_target(entity, target) == false then
		return nil
	end
	return target
end

-- Attacking, what an attack order names or the ground an attack-ground order does (`aim_of`): close in on it until one
-- of the weapons the order fires can shoot it (the manual-fire ones for a launch, `Order.launch`, and the rest
-- otherwise), and let them. An order to attack what none of its weapons can be turned on, like a fighter told to attack
-- a tank, is no order at all. An unarmed unit walks onto it instead, and a bomber flies over it on a bombing run. The
-- ground goes nowhere, so the order to attack it lasts until another replaces it.
local function run_attack(entity: Entity, order: Order)
	local def = entity.def
	local aim = aim_of(entity, order)
	if aim == nil or can_attack(entity, aim) == false then
		attack_orders.set(entity, nil)
		pop(entity)
		return
	end
	local launch = order.launch == true
	attack_orders.set(entity, aim, launch)
	local position = sight.position_of(aim)
	local target = sight.target_of(aim)

	-- it closes in on what the longest of the weapons the order fires that can shoot at it reaches: a gunship's anti air
	-- missiles reach further than its guns, but the guns are what a tank is attacked with
	local reach = shot_rules.reach_against(def, aim, launch) or unit_defs.order_range(def, launch)
	if reach == nil then
		approach(entity, position, movement.ARRIVAL_RADIUS)
		if is_immobile(entity) then
			pop(entity)
		end
		return
	end
	if is_bomber(def) then
		run_bombing(entity, position)
		return
	end
	-- what cannot move out of reach, a building or the ground, is shot from wherever it already can be: from high ground
	-- a shell reaches further than its range on the level, and walking on in to well within range, off the high ground
	-- or into the building's own reach, is only for what might move off
	if (target == nil or target.kind == "building") and targeting.can_shoot(entity, aim) then
		return
	end
	-- in range is not enough: something behind a hill cannot be shot, so it walks on until it can see it, as far as
	-- touching it, and no further, so that it never presses into a building it cannot see over
	if approach(entity, position, reach * RANGE_MARGIN) then
		if targeting.can_shoot(entity, aim) == false then
			local touching = if target ~= nil
				then unit_defs.collider_radius(def) + unit_defs.collider_radius(target.def)
				else movement.ARRIVAL_RADIUS
			approach(entity, position, touching)
		elseif target ~= nil then
			-- a gunship keeps circling it as it fires
			orbit(entity, target, "gunship", 0, reach)
		end
	end
end

-- The commander's disintegrator at a point: close in until the point is within the weapon's range, then fire
-- as soon as it is ready and that is the order done. A weapon that is still reloading, or a team that is short
-- of the energy for it, is waited for, but a shot that an enemy commander is in the way of is dropped, since
-- nothing is going to change that. A unit with no manual weapon drops it.
local function run_dgun(entity: Entity, order: Order)
	local position = order.position
	local weapon = entity.def.manual_weapon
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
	if manual_weapons.fire(entity, position) ~= "waiting" then
		pop(entity)
	end
end

local function run_reclaim(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id, true) else nil
	if target == nil then
		pop(entity)
		return
	end
	if reclaim.can_reclaim(entity, target) == false then
		pop(entity)
		return
	end
	local reach = work_range(entity, order_kinds.RECLAIM_RANGE)
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
	local reach = work_range(entity, order_kinds.RESURRECT_RANGE)
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
	local def = entity.def
	if unit_defs.does(def, "assist") == false then
		pop(entity)
		return
	end
	local reach = work_range(entity, order_kinds.BUILD_RANGE)
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
	if target == nil or construction.can_repair(entity, target) == false then
		pop(entity)
		return
	end
	local reach = work_range(entity, order_kinds.BUILD_RANGE)
	if approach(entity, nearest_point_on(entity, target), reach * RANGE_MARGIN) then
		construction.repair(entity, target)
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
	spatial.each_near(center.X, center.Z, radius, function(other: Entity)
		if geometry.distance_2d(other.position, center) > radius or matches(other) == false then
			return
		end
		local distance = geometry.distance_2d(entity.position, other.position)
		if distance < best_distance then
			best = other
			best_distance = distance
		end
	end)
	return best
end

local function run_area_reclaim(entity: Entity, order: Order)
	local def = entity.def
	if unit_defs.does(def, "reclaim") == false then
		pop(entity)
		return
	end
	run_area(entity, order, "reclaim", function(who, center, radius)
		return nearest_in_radius(who, center, radius, function(other)
			return other.alive and unit_defs.is_remains(other.def) and reclaim.can_reclaim(who, other)
		end)
	end)
end

local function run_area_repair(entity: Entity, order: Order)
	local def = entity.def
	if unit_defs.does(def, "repair") == false then
		pop(entity)
		return
	end
	run_area(entity, order, "repair", function(who, center, radius)
		return nearest_in_radius(who, center, radius, function(other)
			return construction.can_repair(who, other)
		end)
	end)
end

local function run_area_resurrect(entity: Entity, order: Order)
	local def = entity.def
	if unit_defs.does(def, "resurrect") == false then
		pop(entity)
		return
	end
	run_area(entity, order, "resurrect", function(who, center, radius)
		return nearest_in_radius(who, center, radius, function(other)
			return other.alive and resurrection.can_resurrect(who, other)
		end)
	end)
end

local function run_area_attack(entity: Entity, order: Order)
	run_area(entity, order, "attack", function(who, center, radius)
		return nearest_in_radius(who, center, radius, function(other)
			return targeting.is_enemy(who, other) and can_attack(who, other)
		end)
	end)
end

-- Guarding: stay with a friendly entity, its own team's or an ally's. A builder that can assist instead works on
-- whatever the guarded entity is building or reclaiming, and falls back to following when it is doing neither. The
-- order ends if the guarded entity's team stops being an ally.
local function run_guard(entity: Entity, order: Order)
	local target_id = order.target_id
	local target = if target_id ~= nil then state.get(target_id) else nil
	if target == nil or target.id == entity.id or alliances.are_allied(entity.team, target.team) == false then
		pop(entity)
		return
	end

	local def = entity.def
	if unit_defs.does(def, "assist") then
		local blueprint = work.recent(target.id, "build")
		if blueprint ~= nil then
			local reach = work_range(entity, order_kinds.BUILD_RANGE) * RANGE_MARGIN
			if approach(entity, nearest_point_on(entity, blueprint), reach) then
				construction.request(entity, blueprint)
			end
			return
		end

		local reclaimed = work.recent(target.id, "reclaim")
		if reclaimed ~= nil and reclaim.can_reclaim(entity, reclaimed) then
			if approach(entity, reclaimed.position, work_range(entity, order_kinds.RECLAIM_RANGE) * RANGE_MARGIN) then
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
		local target_def = target.def
		local gap = unit_defs.collider_radius(def) + unit_defs.collider_radius(target_def) + GUARD_FOLLOW_GAP
		settled = approach(entity, target.position, gap)
	end

	-- If settled and there are other orders queued, drop guard and do the queued work instead
	if settled and #entity.orders > 1 then
		pop(entity)
		return
	end

	local reach = work_range(entity, order_kinds.BUILD_RANGE) * RANGE_MARGIN
	if
		settled
		and construction.can_repair(entity, target)
		and geometry.distance_2d(entity.position, nearest_point_on(entity, target)) <= reach
	then
		construction.repair(entity, target)
	end
end

-- The blueprint of `def_name` already standing at `position` on `team`, if any.
local function find_blueprint(team: types.TeamId, def_name: string, position: Vector3): Entity?
	local function matches(other: Entity): boolean
		return other.alive
			and other.state == "blueprint"
			and other.team == team
			and other.def_name == def_name
			and geometry.distance_2d(other.position, position) < BLUEPRINT_MATCH_RADIUS
	end
	local found: Entity? = nil
	spatial.each_near(position.X, position.Z, BLUEPRINT_MATCH_RADIUS, function(other: Entity)
		if found == nil and matches(other) then
			found = other
		end
	end)
	if found ~= nil then
		return found
	end
	-- one started this tick has not joined the world yet, and is not in `spatial`
	for _, other in state.pending() do
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
-- BUILD_STUCK_SECONDS with no improvement.
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
	return wait.stuck >= BUILD_STUCK_SECONDS
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
	if first.kind == "guard" and depth < GUARD_CHAIN_DEPTH then
		local guarded = if first.target_id ~= nil then state.get(first.target_id) else nil
		return guarded == nil or is_idle(guarded, depth + 1)
	end
	return false
end

-- Sends `unit` off the footprint about `center` with half extents `half` (on the ground, already turned), ahead of
-- whatever it was doing: straight away from its middle, or `outward` if that is back the other way (a lab's doorway,
-- which it is not to go back into), until it is clear of its corners by VACATE_GAP, and the other way if that is off
-- the map. It is how a build site or a lab's doorway is cleared of what stands on it.
local function vacate(unit: Entity, center: Vector3, half: Vector2, outward: Vector3?)
	local unit_def = unit.def
	local reach = half.Magnitude + unit_defs.collider_radius(unit_def) + VACATE_GAP
	local away = geometry.flatten(unit.position - center)
	local direction = if away.Magnitude < 1e-3 then outward or Vector3.xAxis else away.Unit
	if outward ~= nil and direction:Dot(outward) < 0 then
		direction = outward
	end
	local point = center + direction * reach
	if heightmap.in_bounds(point.X, point.Z) == false then
		point = center - direction * reach
	end
	push_move(unit, surface.position(unit_def, point.X, point.Z), true)
end

-- The builder is at its site but something stands on it. A wreck or reclaimable is reclaimed first, and idle units of its own
-- team are told to move off; anything else, or units that are busy, stay in the way. Ten seconds without
-- fewer things in the way and the order is dropped.
local function clear_site(entity: Entity, order: Order, def_name: string, position: Vector3, facing: number)
	local half = geometry.rotated_half_extents(unit_defs.footprint_half_extents(unit_defs.get(def_name)), facing)
	local blockers = placement.overlapping(def_name, position, facing, entity)
	for _, other in blockers do
		if unit_defs.is_remains(other.def) then
			if reclaim.can_reclaim(entity, other) then
				-- reclaim it first; the build order is still there under it when that is done
				table.insert(entity.orders, 1, { kind = "reclaim", position = nil, target_id = other.id })
				build_waits[entity.id] = nil
				return
			end
		elseif placement.clearable(other, entity.team) and is_idle(other, 0) then
			vacate(other, position, half)
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
	local def = entity.def
	if position == nil or def_name == nil or facing == nil or unit_defs.does(def, "assist") == false then
		drop_build(entity)
		return
	end
	-- nothing its team has not unlocked in the campaign, even if it was ordered while it had
	if build_rules.allows(entity.team, def_name) == false then
		drop_build(entity)
		return
	end
	local nearest = nearest_point_of(def_name, position, facing, entity.position)
	if approach(entity, nearest, work_range(entity, order_kinds.BUILD_RANGE) * RANGE_MARGIN) == false then
		if build_stuck(entity, order, "approach", geometry.distance_2d(entity.position, nearest)) then
			drop_build(entity)
		end
		return
	end

	local blueprint = find_blueprint(entity.team, def_name, position)
	if blueprint == nil then
		local placeable, reason = placement.can_place(def_name, position, facing, entity)
		if placeable == false then
			if reason == "blocked" then
				clear_site(entity, order, def_name, position, facing)
			else
				drop_build(entity)
			end
			return
		end
		blueprint = state.create_entity(def_name, entity.team, position, facing, "blueprint")
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
	if position == nil or entity.def.transport == nil then
		pop(entity)
		return
	end
	if approach(entity, position, movement.ARRIVAL_RADIUS) and transport.lower(entity) then
		transport.unload(entity, position)
		pop(entity)
	end
end

-- A building that builds, like a construction turret, cannot be ordered anywhere. It works on its
-- own, on whatever is nearest within its reach (`work_nearby`). An idle builder with a reach of its own that can move
-- helps build and repair the same way, but reclaims only when told to, so it does not eat the map around it.
local function run_static_builder(entity: Entity)
	local reach = unit_defs.build_range(entity.def)
	if reach ~= nil then
		work_nearby(entity, reach, is_immobile(entity))
	end
end

-- What carries out each kind of order, and whether it keeps the target or point the unit was ordered to shoot at. Only
-- the attacks do: every other order calls that off, and leaves the unit's weapons to pick their own targets.
type Runner = { run: (Entity, Order) -> (), keeps_target: boolean }
local RUNNERS: { [types.OrderKind]: Runner } = {
	move = { run = run_move, keeps_target = false },
	fight = { run = run_fight, keeps_target = false },
	attack = { run = run_attack, keeps_target = true },
	attack_ground = { run = run_attack, keeps_target = true },
	dgun = { run = run_dgun, keeps_target = false },
	reclaim = { run = run_reclaim, keeps_target = false },
	resurrect = { run = run_resurrect, keeps_target = false },
	assist = { run = run_assist, keeps_target = false },
	guard = { run = run_guard, keeps_target = false },
	repair = { run = run_repair, keeps_target = false },
	build = { run = run_build, keeps_target = false },
	load = { run = run_load, keeps_target = false },
	unload = { run = run_unload, keeps_target = false },
	area_reclaim = { run = run_area_reclaim, keeps_target = false },
	area_repair = { run = run_area_repair, keeps_target = false },
	area_resurrect = { run = run_area_resurrect, keeps_target = false },
	area_attack = { run = run_area_attack, keeps_target = true },
}
table.freeze(RUNNERS)

local function tick(delta: number)
	tick_delta = delta
	for _, entity in state.all() do
		-- one being piloted does what its pilot does, and its orders wait until it is let go; a stunned one's wait until it
		-- can move again. Remains take no orders and do no work.
		if control.mode_of(entity) ~= "orders" then
			continue
		end
		if unit_defs.takes_orders(entity.def) == false then
			continue
		end
		-- a lab's orders are for the units it makes, which each take a copy (see production's rally_order)
		if unit_defs.is_factory(entity.def) then
			continue
		end
		-- one on its way out of the lab that made it does nothing else until it is out: production drives it,
		-- and its orders wait
		if movement.exiting_from(entity.id) ~= nil then
			continue
		end

		local order = entity.orders[1]
		-- an attack that has launched a stockpiled missile at its target is done: one order sends one missile
		local launched = attack_orders.take_launch(entity.id)
		if launched and order ~= nil and (order.kind == "attack" or order.kind == "attack_ground") then
			attack_orders.set(entity, nil)
			pop(entity)
			order = entity.orders[1]
		end
		if order == nil then
			attack_orders.set(entity, nil)
			-- with nothing to do, a turret helps build what is near it
			run_static_builder(entity)
			continue
		end

		local runner = RUNNERS[order.kind]
		if runner.keeps_target == false then
			attack_orders.set(entity, nil)
		end
		runner.run(entity, order)
	end
end

-- A unit that is gone takes what it was waiting on with it: at a build site, however its build order ended, or for
-- another look for a way round.
local function forget(id: types.EntityId)
	build_waits[id] = nil
	looked_in_vain[id] = nil
end

snapshot.keep("orders", function()
	return { tick_delta = tick_delta, looked_in_vain = looked_in_vain, build_waits = build_waits }
end, function(saved)
	tick_delta = saved.tick_delta
	looked_in_vain = saved.looked_in_vain
	build_waits = saved.build_waits
end)

return table.freeze({
	forget = forget,
	issue = issue,
	push_move = push_move,
	vacate = vacate,
	tick = tick,
})
