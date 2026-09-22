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
-- How much longer the unit is stunned/impulsed (cannot accelerate), in seconds. Applies when a unit is hit by weapons.
local impulse_remaining: { [EntityId]: number } = {}

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

-- Stuns a unit when hit by a weapon, reducing acceleration for `duration` seconds.
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
	local def = unit_defs.get(entity.def_name)
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

-- Rebuilt once at the top of every tick from every alive, non-aircraft entity: units and buildings
-- alike push, and are pushed against, since a builder is as real an obstacle as another unit. Wrecks
-- are left out: BAR doesn't collide units against them, and with dozens of wrecks lying around after
-- a fight, giving each one a collider would mean every unit near a battlefield pushing against all of
-- them for the rest of the match.
local function rebuild_grids()
	flat_grid.clear(mover_grid)
	flat_grid.clear(other_grid)
	table.clear(mover_slot)
	for _, entity in state.all() do
		if entity.alive == false or entity.kind == "wreck" or air.is_aircraft(entity) then
			continue
		end
		local radius = unit_defs.collider_radius(unit_defs.get(entity.def_name))
		local position = entity.position
		if is_mobile(entity) then
			mover_slot[entity.id] = flat_grid.add(mover_grid, position.X, position.Z, radius)
		else
			flat_grid.add(other_grid, position.X, position.Z, radius)
		end
	end
	flat_grid.sort(mover_grid)
	flat_grid.sort(other_grid)
end

-- Adds to (px, pz) the push from every entry of `grid` overlapping a collider of `radius` at (x, z),
-- skipping entry `self` (0 for none). The push is away from each, scaled by how deep the overlap is so
-- that lightly touching units barely react.
local function push_from(
	grid: Grid,
	x: number,
	z: number,
	radius: number,
	id: EntityId,
	self: number,
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
				if k == self then
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
	local px, pz = push_from(mover_grid, x, z, radius, entity.id, k, 0, 0)
	px, pz = push_from(other_grid, x, z, radius, entity.id, 0, px, pz)
	return Vector3.new(px, 0, pz)
end

-- Climbs or descends an aircraft toward the height it should be at: its flying altitude while it has
-- somewhere to go, and for a moment after, and the ground once it has been idle for a while.
local function fly(entity: Entity, def: types.EntityDef, aircraft: types.Aircraft, busy: boolean, delta: number)
	local idle = idle_for[entity.id]
	if busy then
		idle = 0
	elseif idle == nil then
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
	if hover ~= nil then
		wanted = math.max(floor, hover)
	elseif idle < config.AIR_LAND_DELAY then
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

local function tick(delta: number)
	update_impulses(delta)
	rebuild_grids()
	for _, entity in state.all() do
		if entity.alive == false or is_mobile(entity) == false then
			continue
		end

		local def = unit_defs.get(entity.def_name)
		local max_speed = def.max_speed :: number
		local acceleration = def.acceleration :: number

		-- Reduce acceleration if the unit is impulsed (hit by a weapon)
		if impulse_remaining[entity.id] ~= nil and impulse_remaining[entity.id] > 0 then
			acceleration = 0
		end

		local desired_velocity = Vector3.zero
		local goal = goals[entity.id]
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
		end

		if air.is_aircraft(entity) == false then
			desired_velocity += separation(entity) * config.SEPARATION_STRENGTH
		end
		if desired_velocity.Magnitude > max_speed then
			desired_velocity = desired_velocity.Unit * max_speed
		end

		local change = desired_velocity - entity.velocity
		local max_change = acceleration * delta
		if change.Magnitude > max_change then
			change = change.Unit * max_change
		end
		entity.velocity += change

		if entity.velocity.Magnitude > config.MOVEMENT_SETTLE_SPEED then
			local next_position = entity.position + entity.velocity * delta
			if heightmap.in_bounds(next_position.X, next_position.Z) then
				entity.facing = math.atan2(entity.velocity.X, entity.velocity.Z)
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
		else
			entity.velocity = Vector3.zero
		end

		local aircraft = def.air
		if aircraft ~= nil then
			-- one with something hanging from it stays up, however idle it is, and so does one with orders left to
			-- carry out, like a builder that has arrived and is working, or a gunship holding over its target
			local busy = goal ~= nil
				or entity.velocity.Magnitude > 1
				or #state.cargo_of(entity.id) > 0
				or #entity.orders > 0
			fly(entity, def, aircraft, busy, delta)
		end
	end
end

local function has_goal(entity_id: EntityId): boolean
	return goals[entity_id] ~= nil
end

local function forget(entity_id: EntityId)
	idle_for[entity_id] = nil
	impulse_remaining[entity_id] = nil
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
})
