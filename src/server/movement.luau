--!native
-- Unit steering. There is no pathfinding yet: a unit drives straight at its goal, slowing down so
-- that it stops on the spot rather than overshooting, and pushes gently away from its neighbours
-- so a group that shares a destination spreads into a blob instead of stacking into one point.
--
-- Goals are set fresh every tick by `orders`, so a unit with nothing to do simply coasts to a halt.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local passability = require(ReplicatedStorage.Shared.passability)

local state = require(script.Parent.state)
local air = require(script.Parent.air)
local flat_grid = require(script.Parent.flat_grid)
local pilots = require(script.Parent.pilots)
local emp = require(script.Parent.emp)

type Entity = types.Entity
type EntityId = types.EntityId

type Goal = {
	position: Vector3,
	stop_radius: number,
	-- true when the unit is only passing this point on its way to another, so it keeps its speed
	-- rather than slowing to stop on it
	through: boolean,
	-- how fast the goal is moving itself, on the ground, which the unit matches once it has caught up
	velocity: Vector3,
}

local goals: { [EntityId]: Goal } = {}
-- The height, in the world, an aircraft has been told to hover at this tick instead of its usual altitude.
local hovers: { [EntityId]: number } = {}
-- How long each aircraft has had nowhere to go, in seconds. One that has never been sent anywhere is not in
-- here, and is on the ground.
local idle_for: { [EntityId]: number } = {}
-- How much longer the unit is shaken by a hit, in seconds, and gets only HIT_ACCELERATION of its acceleration.
local impulse_remaining: { [EntityId]: number } = {}
-- The share of its acceleration a unit that has just been hit keeps. Never none: a unit under steady fire is hit again
-- before it recovers, and one with no acceleration at all cannot turn or slow, so it would drift on in a straight line,
-- often further into the fire, for as long as the fire kept up.
local HIT_ACCELERATION = 0.5
-- How high a pilot may take an aircraft that hovers, as many times its usual height.
local PILOT_CEILING = 1.5
-- The lab each unit that has just been made is on its way out of. The two do not push each other apart until the
-- unit is clear of it (see production.luau).
local exiting: { [EntityId]: EntityId } = {}
-- The way each plane on wings that is up against the edge of the map is sliding along it, kept for as long as it
-- stays there so that it goes on one way while its heading turns past the edge's normal, rather than back and forth.
local edge_slides: { [EntityId]: Vector3 } = {}

local function begin_tick()
	table.clear(goals)
	table.clear(hovers)
end

-- Reduce impulse timers by delta. Called at the start of the movement tick.
local function update_impulses(delta: number)
	for id, remaining in impulse_remaining do
		remaining -= delta
		if remaining <= 0 then
			impulse_remaining[id] = nil
		else
			impulse_remaining[id] = remaining
		end
	end
end

local function set_goal(entity: Entity, position: Vector3, stop_radius: number, through: boolean)
	goals[entity.id] = { position = position, stop_radius = stop_radius, through = through, velocity = Vector3.zero }
end

-- A goal that is itself moving, at `velocity`: the unit slows as it closes in like it does for any goal, and
-- once it is there it keeps pace with it instead of stopping.
local function set_tracking_goal(entity: Entity, position: Vector3, stop_radius: number, velocity: Vector3)
	goals[entity.id] = {
		position = position,
		stop_radius = stop_radius,
		through = false,
		velocity = Vector3.new(velocity.X, 0, velocity.Z),
	}
end

-- Tells an aircraft to hover at `height` this tick, wherever that is, instead of at its flying altitude.
local function set_hover(entity: Entity, height: number)
	hovers[entity.id] = height
end

-- Shakes a unit hit by a weapon, reducing its acceleration for `duration` seconds.
local function set_impulse(entity: Entity, duration: number)
	impulse_remaining[entity.id] = duration
end

local function is_mobile(entity: Entity): boolean
	if entity.state ~= "active" then
		return false
	end
	if entity.kind ~= "unit" then
		return false
	end
	local def = unit_defs.of(entity)
	return def.max_speed ~= nil and def.acceleration ~= nil
end

-- Whether `def` may stand at (x, z): the water there is the right depth for it, and the ground is not steeper
-- than its slope class allows.
local function standable(def: types.EntityDef, x: number, z: number): boolean
	local depth = heightmap.water_depth(x, z)
	return unit_defs.tolerates_water(def, depth, depth) and passability.passable_at(def.slope_class, x, z)
end

-- Ground and water traffic push each other apart; aircraft do not. In BAR, planes mostly fly
-- through one another rather than jostling for space, and skipping them here means the crowd that
-- actually needs separation - everyone standing on the ground - is not paying to scan over every
-- aircraft in the sky, or the other way round.
--
-- Neighbours are found through flat grids (see flat_grid.luau) rebuilt once a tick (see
-- `rebuild_grids`), so a mover only ever looks at its own cell and the ring of cells around it, however
-- many entities are alive in total.
--
-- A 3x3 scan only finds every real neighbour if a cell is at least as wide as the furthest two
-- colliders can interact (their radii plus the padding). Movers are all small, but buildings are
-- not, and one cell size for both would have to fit the biggest building - packing a crowd of small
-- movers many to a cell, each checking all of them. So there are two grids: movers in cells sized to
-- two of the widest mover, and everything else that pushes (buildings, blueprints, anything that
-- cannot move) in cells sized to the widest mover plus the widest anything. Only movers ever ask.
local PAD = config.SEPARATION_RADIUS_PADDING

local widest_mover = 0
local widest_any = 0
for _, def in unit_defs.defs do
	if def.air ~= nil then
		continue
	end
	local radius = unit_defs.collider_radius(def)
	if def.kind == "unit" and def.max_speed ~= nil and def.acceleration ~= nil then
		widest_mover = math.max(widest_mover, radius)
	end
	widest_any = math.max(widest_any, radius)
end

type Grid = flat_grid.Grid

local mover_grid = flat_grid.new(2 * widest_mover + PAD, 256)
local other_grid = flat_grid.new(widest_mover + widest_any + PAD, 128)
-- Where each mover sits in mover_grid this tick, by id.
local mover_slot: { [EntityId]: number } = {}
-- Who is in each slot of other_grid this tick.
local other_ids: { EntityId } = {}

-- Rebuilt once at the top of every tick from every alive, non-aircraft entity: units and buildings
-- alike push, and are pushed against, since a builder is as real an obstacle as another unit. Wrecks
-- are left out: BAR doesn't collide units against them, and with dozens of wrecks lying around after
-- a fight, giving each one a collider would mean every unit near a battlefield pushing against all of
-- them for the rest of the match. Reclaimables are left out for the same reason, as the wrecks they are like.
local function rebuild_grids()
	flat_grid.clear(mover_grid)
	flat_grid.clear(other_grid)
	table.clear(mover_slot)
	table.clear(other_ids)
	for _, entity in state.all() do
		if
			entity.alive == false
			or entity.kind == "wreck"
			or entity.kind == "reclaimable"
			or air.is_aircraft(entity)
		then
			continue
		end
		local radius = unit_defs.collider_radius(unit_defs.of(entity))
		local position = entity.position
		if is_mobile(entity) then
			mover_slot[entity.id] = flat_grid.add(mover_grid, position.X, position.Z, radius)
		else
			other_ids[flat_grid.add(other_grid, position.X, position.Z, radius)] = entity.id
		end
	end
	flat_grid.sort(mover_grid)
	flat_grid.sort(other_grid)
end

-- Adds to (px, pz) the push from every entry of `grid` overlapping a collider of `radius` at (x, z),
-- skipping entry `self` (0 for none) and the entry whose id in `ids` is `passes` (nil for none). The push is away from each, scaled by how deep the overlap is so
-- that lightly touching units barely react.
local function push_from(
	grid: Grid,
	x: number,
	z: number,
	radius: number,
	id: EntityId,
	self: number,
	ids: { EntityId }?,
	passes: EntityId?,
	px: number,
	pz: number
): (number, number)
	local size, side = grid.size, grid.side
	local xs, zs, rs, order, starts, stops = grid.xs, grid.zs, grid.rs, grid.order, grid.starts, grid.stops
	local cx, cz = math.floor(x / size), math.floor(z / size)
	for dz = -1, 1 do
		local row = ((cz + dz) % side) * side
		for dx = -1, 1 do
			local c = row + ((cx + dx) % side) + 1
			for s = starts[c], stops[c] - 1 do
				local k = order[s]
				if k == self or (ids ~= nil and ids[k] == passes) then
					continue
				end
				local ox, oz = x - xs[k], z - zs[k]
				local minimum = radius + rs[k] + PAD
				local distance_squared = ox * ox + oz * oz
				if distance_squared >= minimum * minimum then
					continue
				end
				if distance_squared < 1e-6 then
					-- exactly co-located: shove apart along an arbitrary but stable axis
					local angle = id * 2.399963
					px += math.cos(angle)
					pz += math.sin(angle)
					continue
				end
				local distance = math.sqrt(distance_squared)
				local scale = (minimum - distance) / (minimum * distance)
				px += ox * scale
				pz += oz * scale
			end
		end
	end
	return px, pz
end

-- The push on a mover from everything overlapping it, judged from where everything stood at the top
-- of the tick. Only movers that are not aircraft have a slot - see `rebuild_grids`.
local function separation(entity: Entity): Vector3
	local k = mover_slot[entity.id]
	if k == nil then
		return Vector3.zero
	end
	local x, z, radius = mover_grid.xs[k], mover_grid.zs[k], mover_grid.rs[k]
	local px, pz = push_from(mover_grid, x, z, radius, entity.id, k, nil, nil, 0, 0)
	local lab = exiting[entity.id]
	px, pz = push_from(other_grid, x, z, radius, entity.id, 0, if lab ~= nil then other_ids else nil, lab, px, pz)
	return Vector3.new(px, 0, pz)
end

-- Climbs or descends an aircraft toward the height it should be at: its flying altitude while it has
-- somewhere to go, and for a moment after, and the ground once it has been idle for a while. One on wings
-- cannot wait in the air, so it comes down the moment it has nothing to do. One that hovers and is `stunned` sinks
-- to the ground, as BAR's do.
local function fly(
	entity: Entity,
	def: types.EntityDef,
	aircraft: types.Aircraft,
	busy: boolean,
	stunned: boolean,
	delta: number
)
	local idle = idle_for[entity.id]
	if busy then
		idle = 0
	elseif idle == nil or aircraft.wings ~= nil then
		idle = config.AIR_LAND_DELAY
	else
		idle += delta
	end
	idle_for[entity.id] = idle

	local x = entity.position.X
	local z = entity.position.Z
	local floor = air.resting_height(def, x, z)
	local wanted = floor
	local hover = hovers[entity.id]
	if stunned and aircraft.wings == nil then
		wanted = floor
	elseif hover ~= nil then
		wanted = math.max(floor, hover)
	elseif idle < config.AIR_LAND_DELAY then
		wanted += aircraft.altitude * config.AIR_ALTITUDE_SCALE
	end

	local step = aircraft.climb_speed * delta
	local y = entity.position.Y
	if y < wanted then
		y = math.min(wanted, y + step)
	else
		y = math.max(wanted, y - step)
	end
	-- whatever it is doing, it never goes into the ground, however the ground rises under it
	entity.position = Vector3.new(x, math.max(y, floor), z)
end

-- A plane on wings that is circling, or flying on past its goal to come round at it, looks this many of its turning
-- circle's radii ahead, and if that is off the map it turns for the middle of the map instead, so that it has come
-- round before it gets to the edge.
local WINGS_EDGE_LOOKAHEAD = 1.5
-- A plane on wings that reaches the edge of the map slides along it the way it is flying if at least this much of what
-- it would fly in a tick is along the edge, and otherwise the way it is turning (see `tick`).
local EDGE_GRAZE = 0.3

-- Whether (x, z) is at least `margin` studs inside the edge of the map, which is centred on the origin.
local function well_inside(x: number, z: number, margin: number): boolean
	local hx, hz = heightmap.half_extents()
	return math.abs(x) <= hx - margin and math.abs(z) <= hz - margin
end

-- The velocity an aircraft on `wings` flies at this tick. It only ever flies forward, along its heading, which it
-- turns no faster than its turn rate toward `goal`, if it has one, or else circles. While it is `busy` it flies flat
-- out; once it is not, it slows to a stop, which is what it does as it comes down to land. A goal behind it and
-- nearer than its run-out is flown away from, straight, until it is not, as BAR's planes do, so that it comes
-- round at the goal from far enough out to line up on it. Circling, or flying away like that, it turns in from the
-- edge of the map before it gets there (WINGS_EDGE_LOOKAHEAD); flying at a goal, it may reach the edge, and `tick` has
-- it slide along it.
local function steer_wings(
	entity: Entity,
	wings: types.Wings,
	goal: Goal?,
	busy: boolean,
	max_speed: number,
	acceleration: number,
	delta: number
): Vector3
	local heading = entity.facing
	local forward = Vector3.new(math.sin(heading), 0, math.cos(heading))
	local speed = if busy then max_speed else 0
	local wanted_heading = heading
	local offset = if goal ~= nil then geometry.flatten(goal.position - entity.position) else Vector3.zero
	local making_room = false
	if goal == nil or offset.Magnitude <= goal.stop_radius then
		if busy then
			wanted_heading = heading + math.pi / 2
			making_room = true
		end
	elseif offset:Dot(forward) > 0 or offset.Magnitude >= wings.run_out then
		wanted_heading = math.atan2(offset.X, offset.Z)
	else
		making_room = true
	end
	if making_room then
		local ahead = entity.position + forward * (max_speed / wings.turn_rate * WINGS_EDGE_LOOKAHEAD)
		if not well_inside(ahead.X, ahead.Z, 0) then
			wanted_heading = math.atan2(-entity.position.X, -entity.position.Z)
		end
	end

	local max_turn = wings.turn_rate * delta
	local turn = (wanted_heading - heading + math.pi) % (2 * math.pi) - math.pi
	heading += math.clamp(turn, -max_turn, max_turn)
	entity.facing = heading

	local current = entity.velocity.Magnitude
	local max_change = acceleration * delta
	current += math.clamp(speed - current, -max_change, max_change)
	return Vector3.new(math.sin(heading), 0, math.cos(heading)) * current
end

local function tick(delta: number)
	update_impulses(delta)
	rebuild_grids()
	for _, entity in state.all() do
		if entity.alive == false or is_mobile(entity) == false then
			continue
		end

		local def = unit_defs.of(entity)
		local max_speed = def.max_speed :: number
		local acceleration = def.acceleration :: number

		-- a unit that has just been hit answers slower, but still answers
		if impulse_remaining[entity.id] ~= nil and impulse_remaining[entity.id] > 0 then
			acceleration *= HIT_ACCELERATION
		end

		local desired_velocity = Vector3.zero
		-- which way its goal draws it, if it has one that is drawing it anywhere
		local drawn_toward: Vector3? = nil
		-- something stunned goes nowhere of its own accord, whatever it was told or its pilot steers
		local stunned = emp.is_stunned(entity)
		local goal = if stunned then nil else goals[entity.id]
		-- one being piloted goes where its pilot steers it, as fast as it can go, whatever it was told to do; a plane on
		-- wings, which can only fly on ahead, makes for a point far off the way its pilot looks
		local pilot = if stunned then nil else pilots.get(entity.id)
		if pilot ~= nil then
			goal = nil
			desired_velocity = pilot.steer * max_speed
			-- one that hovers flies as high over the ground as its pilot takes it, from on it to a little over its usual
			-- height
			local hovering = def.air
			if hovering ~= nil and hovering.wings == nil then
				local height = if pilot.height ~= nil then pilot.height else hovering.altitude
				height =
					math.clamp(height + pilot.lift * hovering.climb_speed * delta, 0, hovering.altitude * PILOT_CEILING)
				pilot.height = height
				hovers[entity.id] = air.resting_height(def, entity.position.X, entity.position.Z) + height
			end
			if def.air ~= nil and def.air.wings ~= nil then
				goal = {
					position = entity.position + Vector3.new(math.sin(pilot.facing), 0, math.cos(pilot.facing)) * 1e4,
					stop_radius = 0,
					through = true,
					velocity = Vector3.zero,
				}
			end
		end
		if goal ~= nil then
			local offset = geometry.flatten(goal.position - entity.position)
			local distance = offset.Magnitude
			if distance > goal.stop_radius then
				if goal.through then
					desired_velocity = (offset / distance) * max_speed
				else
					-- cap speed at what can still be bled off before reaching the goal
					local braking_speed = math.sqrt(2 * acceleration * math.max(0, distance - goal.stop_radius))
					desired_velocity = (offset / distance) * math.min(max_speed, braking_speed)
				end
			end
			desired_velocity += goal.velocity
			if desired_velocity.Magnitude > config.MOVEMENT_SETTLE_SPEED then
				drawn_toward = desired_velocity.Unit
			end
		end

		if air.is_aircraft(entity) == false then
			desired_velocity += separation(entity) * config.SEPARATION_STRENGTH
		end
		if desired_velocity.Magnitude > max_speed then
			desired_velocity = desired_velocity.Unit * max_speed
		end

		-- one with something hanging from it stays up, however idle it is, and so does one with orders left to
		-- carry out, like a builder that has arrived and is working, or a gunship holding over its target
		local aircraft = def.air
		local wings = if aircraft ~= nil then aircraft.wings else nil
		local busy = aircraft ~= nil
			and (pilot ~= nil or goal ~= nil or #entity.orders > 0 or #state.cargo_of(entity.id) > 0)
		-- a stunned plane on wings glides straight on as it was going, and stays up
		local gliding = stunned and wings ~= nil and air.is_airborne(entity)
		if stunned and gliding == false then
			busy = false
		end

		-- which way a plane on wings is turning, for which way it slides along the edge of the map if it reaches it
		local turning = 0
		if gliding then
			busy = true
		elseif wings ~= nil then
			local facing_before = entity.facing
			entity.velocity = steer_wings(entity, wings, goal, busy, max_speed, acceleration, delta)
			turning = (entity.facing - facing_before + math.pi) % (2 * math.pi) - math.pi
		else
			local change = desired_velocity - entity.velocity
			local max_change = acceleration * delta
			if change.Magnitude > max_change then
				change = change.Unit * max_change
			end
			entity.velocity += change
		end

		if entity.velocity.Magnitude > config.MOVEMENT_SETTLE_SPEED then
			local next_position = entity.position + entity.velocity * delta
			if heightmap.in_bounds(next_position.X, next_position.Z) then
				-- It faces the way it goes when that is where its goal draws it. Going anywhere else it is being
				-- pushed, by a building or the units round it, and gives way without turning: one held against
				-- something in its way, or a builder at the edge of its reach that is pushed out and walks back
				-- in by turns, would otherwise turn right round every tick.
				if drawn_toward ~= nil and entity.velocity:Dot(drawn_toward) >= 0 then
					entity.facing = math.atan2(entity.velocity.X, entity.velocity.Z)
				end
				edge_slides[entity.id] = nil
			elseif wings ~= nil then
				-- a plane cannot stop in the air: it is held at the edge but keeps its heading, which goes on turning away,
				-- and its speed, sliding along the edge, or out of a corner toward the middle, as fast as it was flying
				local hx, hz = heightmap.half_extents()
				local here = entity.position
				local distance = entity.velocity.Magnitude * delta
				-- as much of where it is flying as the edge lets it go: along the edge, if it is flying along it at all
				local clamped =
					Vector3.new(math.clamp(next_position.X, -hx, hx), here.Y, math.clamp(next_position.Z, -hz, hz))
				local grazing = geometry.flatten(clamped - here)
				local slide: Vector3
				if grazing.Magnitude >= EDGE_GRAZE * distance then
					-- going along the edge as much as into it: it slides on the way it is going
					slide = grazing
				else
					-- flying nearly straight into it: it slides the way it will be heading a quarter turn from now, so that
					-- it slides on the way it is coming round and leaves the edge going on the same way, and keeps to
					-- that way for as long as it is on the edge, while its heading turns past the edge's normal
					local remembered = edge_slides[entity.id]
					if remembered ~= nil then
						slide = remembered
					else
						local toward = next_position
						if turning ~= 0 then
							local quarter = entity.facing + math.sign(turning) * math.pi / 2
							toward = here + Vector3.new(math.sin(quarter), 0, math.cos(quarter))
						end
						slide = geometry.flatten(
							Vector3.new(math.clamp(toward.X, -hx, hx), here.Y, math.clamp(toward.Z, -hz, hz)) - here
						)
						if slide.Magnitude < 1e-3 then
							slide = geometry.flatten(-here)
						end
					end
				end
				edge_slides[entity.id] = slide
				local function slid(way: Vector3): Vector3
					local along = if way.Magnitude > 1e-3 then here + way.Unit * distance else here
					return Vector3.new(math.clamp(along.X, -hx, hx), next_position.Y, math.clamp(along.Z, -hz, hz))
				end
				local moved = slid(slide)
				if geometry.flatten(moved - here).Magnitude < distance / 2 then
					-- slid into a corner: out of it toward the middle
					slide = geometry.flatten(-here)
					edge_slides[entity.id] = slide
					moved = slid(slide)
				end
				next_position = moved
			else
				entity.velocity = Vector3.zero
				next_position = entity.position
			end
			-- Water it cannot stand in, and ground too steep for it, are walls: it slides along them, or stops.
			-- Something already standing where it should not, like a wader that was pushed in, may move freely
			-- to get out. Exception: ships that need water cannot move forward onto land - they must reverse course.
			local here = entity.position
			local current_standable = standable(def, here.X, here.Z)
			local next_standable = standable(def, next_position.X, next_position.Z)

			-- If a floating unit (ship) is on land, push it back toward water by reversing its velocity
			if unit_defs.floats(def) and current_standable == false then
				-- Reverse velocity to push back the way it came
				entity.velocity = -entity.velocity
				-- Don't move this tick; next tick it will move back toward water
				next_position = here
			elseif next_standable == false and current_standable then
				if standable(def, next_position.X, here.Z) then
					next_position = Vector3.new(next_position.X, next_position.Y, here.Z)
					entity.velocity = Vector3.new(entity.velocity.X, 0, 0)
				elseif standable(def, here.X, next_position.Z) then
					next_position = Vector3.new(here.X, next_position.Y, next_position.Z)
					entity.velocity = Vector3.new(0, 0, entity.velocity.Z)
				else
					next_position = here
					entity.velocity = Vector3.zero
				end
			end

			-- a ship rides the surface, and everything else stands on what is under it
			local ground = unit_defs.surface_height(def, next_position.X, next_position.Z)
			-- an aircraft keeps the height it is at, which `fly` changes below
			local height = if def.air ~= nil then entity.position.Y else ground + unit_defs.collider_height(def) / 2
			entity.position = Vector3.new(next_position.X, height, next_position.Z)
		elseif drawn_toward == nil then
			-- it settles to a stop only when nothing draws it on: one as slow to get going as BAR's Starlight gains
			-- less than the settle speed in a tick, and has to keep what it gained to ever get over it
			entity.velocity = Vector3.zero
		end
		-- it faces where its pilot looks, whichever way it is going
		if pilot ~= nil and wings == nil then
			entity.facing = pilot.facing
		end

		if aircraft ~= nil then
			-- one that hovers is also kept up by still moving; one on wings is always moving while it is up, and
			-- lands as it slows
			fly(entity, def, aircraft, busy or (wings == nil and entity.velocity.Magnitude > 1), stunned, delta)
		end
	end
end

local function has_goal(entity_id: EntityId): boolean
	return goals[entity_id] ~= nil
end

-- Lets `entity` pass through `lab`, and `lab` through it, until `end_exit`.
local function begin_exit(entity: Entity, lab: Entity)
	exiting[entity.id] = lab.id
end

local function end_exit(entity_id: EntityId)
	exiting[entity_id] = nil
end

-- The lab `entity_id` is on its way out of, if it is.
local function exiting_from(entity_id: EntityId): EntityId?
	return exiting[entity_id]
end

local function forget(entity_id: EntityId)
	idle_for[entity_id] = nil
	impulse_remaining[entity_id] = nil
	exiting[entity_id] = nil
	edge_slides[entity_id] = nil
end

return table.freeze({
	begin_tick = begin_tick,
	set_goal = set_goal,
	set_tracking_goal = set_tracking_goal,
	set_hover = set_hover,
	set_impulse = set_impulse,
	tick = tick,
	forget = forget,
	is_mobile = is_mobile,
	has_goal = has_goal,
	begin_exit = begin_exit,
	end_exit = end_exit,
	exiting_from = exiting_from,
})
