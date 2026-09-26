--!native
-- Unit steering. A unit drives straight at its goal, slowing down so that it stops on the spot rather than
-- overshooting, and pushes gently away from its neighbours so a group that shares a destination spreads into a blob
-- instead of stacking into one point. The way round what is in the way is found before it sets off, and handed to it as
-- a chain of goals (`orders`, shared/pathfinder). It keeps to the ground a route can be laid over
-- (`pathfinder.open_at`), and one held up at its edge says for how long (`held_for`), so that orders can find it a way
-- round something put down across its way since.
--
-- Goals are set fresh every tick by `orders`, so a unit with nothing to do simply coasts to a halt.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)

local state = require(script.Parent.state)
local air = require(script.Parent.air)
local spatial = require(script.Parent.spatial)
local control = require(script.Parent.control)
local pilots = require(script.Parent.pilots)

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
-- Which units had somewhere to go in the last movement step (`had_goal`), kept apart from `goals`, which the next step
-- gathers afresh, so that it can be asked at any point of a step.
local stepped_goals: { [EntityId]: boolean } = {}
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
-- A hovering aircraft still moving faster than this, in studs a second, stays up, as one with somewhere to go does.
local HOVER_KEEP_UP_SPEED = 1
-- How near a unit has to come to where it is sent to be there.
local ARRIVAL_RADIUS = 1.5
-- How hard units push each other apart, which keeps formations from collapsing into a point.
local SEPARATION_STRENGTH = 6
-- A unit whose velocity is below this never bothers with terrain/passability checks or moving at
-- all this tick: it counts as settled. Without a floor here, units at rest but slightly overlapping
-- (idle crowds, builders waiting by a blueprint) get just enough separation push every tick to keep
-- crossing a near-zero threshold, which was paying for a full terrain lookup forever without ever
-- visibly moving.
local MOVEMENT_SETTLE_SPEED = 0.05
-- How long an aircraft with nothing to do hovers before it settles onto the ground. One on wings cannot hover, and
-- comes down at once.
local AIR_LAND_DELAY = 2
-- The lab each unit that has just been made is on its way out of. The two do not push each other apart until the
-- unit is clear of it (see production.luau).
local exiting: { [EntityId]: EntityId } = {}
-- The way each plane on wings that is up against the edge of the map is sliding along it, kept for as long as it
-- stays there so that it goes on one way while its heading turns past the edge's normal, rather than back and forth.
local edge_slides: { [EntityId]: Vector3 } = {}
-- Since when, by `clock`, each unit has been held up by ground it cannot stand on, a building's or a cliff's: stopped at
-- its edge or sliding along it, and not yet off it (`held_for`).
local held_since: { [EntityId]: number } = {}
-- How long movement has run, in seconds.
local clock = 0

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
		idle = AIR_LAND_DELAY
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
	elseif idle < AIR_LAND_DELAY then
		wanted += aircraft.altitude
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
-- it would fly in a tick is along the edge, and otherwise the way it is turning (see `slide_along_edge`).
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
-- edge of the map before it gets there (WINGS_EDGE_LOOKAHEAD); flying at a goal, it may reach the edge, and slides along
-- it (`slide_along_edge`).
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
	local turn = geometry.wrap_angle(wanted_heading - heading)
	heading += math.clamp(turn, -max_turn, max_turn)
	entity.facing = heading

	local current = entity.velocity.Magnitude
	local max_change = acceleration * delta
	current += math.clamp(speed - current, -max_change, max_change)
	return Vector3.new(math.sin(heading), 0, math.cos(heading)) * current
end

-- The goal a piloted unit makes for, which its pilot steers rather than its orders: none for anything but a plane on
-- wings, which can only fly on ahead and so makes for a point far off the way its pilot looks. One that hovers flies as
-- high over the ground as its pilot takes it, from on it to a little over its usual height.
local function pilot_goal(entity: Entity, def: types.EntityDef, pilot: pilots.Pilot, delta: number): Goal?
	local hovering = def.air
	if hovering ~= nil and hovering.wings == nil then
		local height = if pilot.height ~= nil then pilot.height else hovering.altitude
		height = math.clamp(height + pilot.lift * hovering.climb_speed * delta, 0, hovering.altitude * PILOT_CEILING)
		pilot.height = height
		hovers[entity.id] = air.resting_height(def, entity.position.X, entity.position.Z) + height
	end
	if def.air ~= nil and def.air.wings ~= nil then
		return {
			position = entity.position + Vector3.new(math.sin(pilot.facing), 0, math.cos(pilot.facing)) * 1e4,
			stop_radius = 0,
			through = true,
			velocity = Vector3.zero,
		}
	end
	return nil
end

-- The velocity `goal` asks of `entity`, which starts from `desired`, and which way it draws it, if it is drawing it
-- anywhere: at full speed through a point it only passes, and otherwise no faster than it can still stop from before it
-- gets there, and then on at the goal's own pace.
local function toward_goal(
	entity: Entity,
	goal: Goal,
	desired: Vector3,
	max_speed: number,
	acceleration: number
): (Vector3, Vector3?)
	local offset = geometry.flatten(goal.position - entity.position)
	local distance = offset.Magnitude
	if distance > goal.stop_radius then
		if goal.through then
			desired = (offset / distance) * max_speed
		else
			-- cap speed at what can still be bled off before reaching the goal
			local braking_speed = math.sqrt(2 * acceleration * math.max(0, distance - goal.stop_radius))
			desired = (offset / distance) * math.min(max_speed, braking_speed)
		end
	end
	desired += goal.velocity
	if desired.Magnitude > MOVEMENT_SETTLE_SPEED then
		return desired, desired.Unit
	end
	return desired, nil
end

-- Steers something that drives or hovers: its velocity turns toward `desired`, changing by no more than its
-- acceleration allows in a tick.
local function steer_ground(entity: Entity, desired: Vector3, acceleration: number, delta: number)
	local change = desired - entity.velocity
	local max_change = acceleration * delta
	if change.Magnitude > max_change then
		change = change.Unit * max_change
	end
	entity.velocity += change
end

-- Where a plane on wings that would fly out of the map to `next_position` this tick goes instead. It cannot stop in the
-- air: it is held at the edge but keeps its heading, which goes on turning away (by `turning` this tick), and its
-- speed, sliding along the edge, or out of a corner toward the middle, as fast as it was flying.
local function slide_along_edge(entity: Entity, next_position: Vector3, turning: number, delta: number): Vector3
	local hx, hz = heightmap.half_extents()
	local here = entity.position
	local distance = entity.velocity.Magnitude * delta
	-- as much of where it is flying as the edge lets it go: along the edge, if it is flying along it at all
	local clamped = Vector3.new(math.clamp(next_position.X, -hx, hx), here.Y, math.clamp(next_position.Z, -hz, hz))
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
	return moved
end

-- The terrain's say in a step from where `entity` is to `next_position`: water it cannot stand in, ground too steep
-- for it, and buildings are walls (`pathfinder.open_at`), so from ground it can stand on it slides along them, or stops,
-- and it is held up there (`held_for`). Something already standing where it should not, like a wader that was pushed in, a
-- ship left on dry land, or a unit just made inside its factory, may move freely to get out. Returns where it goes.
local function keep_to_standable(entity: Entity, def: types.EntityDef, next_position: Vector3): Vector3
	local here = entity.position
	local standable = pathfinder.open_at
	if standable(def, next_position.X, next_position.Z) or standable(def, here.X, here.Z) == false then
		held_since[entity.id] = nil
		return next_position
	end
	if held_since[entity.id] == nil then
		held_since[entity.id] = clock
	end
	if standable(def, next_position.X, here.Z) then
		entity.velocity = Vector3.new(entity.velocity.X, 0, 0)
		return Vector3.new(next_position.X, next_position.Y, here.Z)
	elseif standable(def, here.X, next_position.Z) then
		entity.velocity = Vector3.new(0, 0, entity.velocity.Z)
		return Vector3.new(here.X, next_position.Y, next_position.Z)
	end
	entity.velocity = Vector3.zero
	return here
end

-- Moves `entity` on by its velocity for `delta` seconds, as far as the map and the terrain let it (`slide_along_edge`,
-- `keep_to_standable`), turning it to face the way it goes when that is the way it is drawn (`drawn_toward`), and puts
-- it at its height there: a ship on the surface, anything else on the ground under it, and an aircraft at the height it
-- is flying at, which `fly` changes.
local function advance(entity: Entity, def: types.EntityDef, drawn_toward: Vector3?, turning: number, delta: number)
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
	elseif def.air ~= nil and def.air.wings ~= nil then
		next_position = slide_along_edge(entity, next_position, turning, delta)
	else
		entity.velocity = Vector3.zero
		next_position = entity.position
	end
	next_position = keep_to_standable(entity, def, next_position)
	local ground = surface.height(def, next_position.X, next_position.Z)
	local height = if def.air ~= nil then entity.position.Y else ground + unit_defs.collider_height(def) / 2
	entity.position = Vector3.new(next_position.X, height, next_position.Z)
end

-- One tick of `entity`'s movement: what it wants (its goal, or its pilot's steering), pushed apart from the units round
-- it, steered the way it gets about (on wings, gliding stunned, or driving and hovering), carried out as far as the
-- terrain lets it (`advance`), and for an aircraft, its climb or descent (`fly`).
local function move(entity: Entity, delta: number)
	local def = entity.def
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
	local stunned = control.mode_of(entity) == "stunned"
	local goal = if stunned then nil else goals[entity.id]
	-- one being piloted goes where its pilot steers it, as fast as it can go, whatever it was told to do
	local pilot = control.pilot_of(entity)
	if pilot ~= nil then
		desired_velocity = pilot.steer * max_speed
		goal = pilot_goal(entity, def, pilot, delta)
	end
	if goal ~= nil then
		desired_velocity, drawn_toward = toward_goal(entity, goal, desired_velocity, max_speed, acceleration)
	end

	if unit_defs.is_air(entity.def) == false then
		-- a unit on its way out of the lab that made it passes through the lab, and the lab through it
		desired_velocity += spatial.separation(entity, exiting[entity.id]) * SEPARATION_STRENGTH
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
		turning = geometry.wrap_angle(entity.facing - facing_before)
	else
		steer_ground(entity, desired_velocity, acceleration, delta)
	end

	if entity.velocity.Magnitude > MOVEMENT_SETTLE_SPEED then
		advance(entity, def, drawn_toward, turning, delta)
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
		fly(
			entity,
			def,
			aircraft,
			busy or (wings == nil and entity.velocity.Magnitude > HOVER_KEEP_UP_SPEED),
			stunned,
			delta
		)
	end
end

local function tick(delta: number)
	clock += delta
	update_impulses(delta)
	for _, entity in state.all() do
		if entity.alive and spatial.is_mobile(entity) then
			move(entity, delta)
		end
	end
	table.clear(stepped_goals)
	for entity_id in goals do
		stepped_goals[entity_id] = true
	end
end

-- Whether `entity_id` had somewhere to go in the last movement step.
local function had_goal(entity_id: EntityId): boolean
	return stepped_goals[entity_id] == true
end

-- Lets `entity` pass through `lab`, and `lab` through it, until `end_exit`.
local function begin_exit(entity: Entity, lab: Entity)
	exiting[entity.id] = lab.id
end

local function end_exit(entity_id: EntityId)
	exiting[entity_id] = nil
end

-- How long `entity_id` has been held up at the edge of ground it cannot stand on, stopped or sliding along it, in
-- seconds: 0 when it is not.
local function held_for(entity_id: EntityId): number
	local since = held_since[entity_id]
	return if since ~= nil then math.max(0, clock - since) else 0
end

-- Starts `entity_id`'s time held up over, for one that has just been given a new way to go.
local function clear_held(entity_id: EntityId)
	held_since[entity_id] = nil
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
	held_since[entity_id] = nil
end

return table.freeze({
	ARRIVAL_RADIUS = ARRIVAL_RADIUS,
	MOVEMENT_SETTLE_SPEED = MOVEMENT_SETTLE_SPEED,
	forget = forget,
	begin_tick = begin_tick,
	set_goal = set_goal,
	set_tracking_goal = set_tracking_goal,
	set_hover = set_hover,
	set_impulse = set_impulse,
	tick = tick,
	had_goal = had_goal,
	begin_exit = begin_exit,
	end_exit = end_exit,
	exiting_from = exiting_from,
	held_for = held_for,
	clear_held = clear_held,
})
