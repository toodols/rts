-- Rockets in flight. A rocket is launched along a line at where its target was, flies the shared
-- projectile model (thrust, then drag and gravity), and explodes on the first solid thing it touches or
-- on the ground. It cares nothing for whose that thing is, which is how a rocket fired past a friend
-- can hit it.
--
-- Clients are told about launches and impacts and fly the same model themselves.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile_mod = require(ReplicatedStorage.Shared.projectile)

local state = require(script.Parent.state)
local deformation = require(script.Parent.deformation)
local shields = require(script.Parent.shields)
local alliances = require(script.Parent.alliances)
local flat_grid = require(script.Parent.flat_grid)
local air = require(script.Parent.air)

type Entity = types.Entity
type EntityId = types.EntityId

type Projectile = {
	id: number,
	owner_id: EntityId,
	team: types.TeamId,
	flight: projectile_mod.Flight,
	params: types.ProjectileParams,
	damage: number,
	-- whether the weapon that fired it is dedicated anti air, which decides how hard it hits aircraft
	anti_air: boolean,
	-- for an EMP weapon's, the longest it stuns for: its damage is EMP (`Weapon.paralyze_time`)
	paralyze_time: number?,
	-- whether it has come out of its launcher's collider yet; until it has, the launcher cannot be struck
	clear_of_owner: boolean,
	-- the shields it was fired from inside, which do not stop it
	exempt: { [EntityId]: boolean },
	-- whether this is a nuclear missile
	is_nuclear: boolean,
	-- where it was fired at: for a nuke, where it will come down, which is what an anti-nuke's coverage is about
	aim: Vector3,
	-- for a nuke, the interceptor sent after it, so that no other is spent on it
	chased_by: number?,
	-- for a nuke, that an interceptor has caught it: it has gone off in the air, and is taken out on its own turn
	intercepted: boolean,
	-- whether this is an anti-nuke interceptor that homes onto nuclear missiles
	is_anti_nuke: boolean,
	-- the nuke projectile this interceptor is homing onto, if any
	homing_target_id: number?,
	-- the entity a homing (non anti-nuke) missile, such as an AA missile, tracks onto, if any
	homing_entity_id: EntityId?,
	-- what it was fired at, if it was fired at something: the one aircraft it can strike
	target_id: EntityId?,
	-- for one that pierces (`ProjectileParams.pierce`), how long until it goes off again inside what it is going
	-- through; nothing while it is in the clear, so it goes off the moment it strikes something
	pierce_wait: number,
}

local weapon_fired: RemoteEvent = ReplicatedStorage.Shared.WeaponFired

-- Collisions are tested at least this often along the flight, so a fast rocket cannot skip through
-- something narrow.
local HIT_STEP = 0.5
-- A homing projectile whose weapon does not give it a guidance time is guided for this many times as long as it
-- takes to fly its weapon's range: long enough to come round once for something that got past it, not long enough
-- to chase it for ever.
local GUIDANCE_MARGIN = 2.5
-- How far clear of its target's collider a missile fired to miss (config.HOMING_MISS_CHANCE) passes.
local MISS_CLEARANCE = 1.5
local miss_roll = Random.new()
-- How big the burst is where a shield swallows a shell.
local SHIELD_BURST_RADIUS = 3
-- The projectile's own thickness.
local PROJECTILE_RADIUS = 0.3
-- How far under the surface a ship's hull reaches, for a torpedo: a ship rests on the water with nothing of its
-- collider below it, but a torpedo running under it has to meet its keel.
local HULL_DRAFT = 1.5
-- How near an interceptor has to come to the nuke it chases to catch it: about the nuke's own length.
local INTERCEPT_RADIUS = 4
-- How often a piercing shot goes off while inside something: every frame of Spring's, where a `noexplode` projectile
-- collides, and so goes off, on every frame it overlaps a unit.
local PIERCE_INTERVAL = 1 / 30

-- Direct-hit and splash checks go through flat grids (see flat_grid.luau) instead of every living thing,
-- rebuilt once a tick while anything is in flight (see `rebuild_grids`). A rocket is tested every half
-- stud of its flight, so each test has to be cheap: it only visits cells within the widest collider
-- that could touch it. Small units and big buildings sit in separate grids so that a rocket flying over
-- a crowd of small units only allows for small-unit widths there, and wrecks - which a rocket flies
-- through but a blast still hurts - sit in a third. Aircraft sit in a fourth, for the same reason: as in BAR
-- they have no collider, so a rocket flies through any aircraft but the one it was fired at, and only a
-- blast reaches the rest. What hangs from a transport is up with them, and is treated as they are.
local SMALL_RADIUS = 4

local widest_collider = 0
for _, def in unit_defs.defs do
	widest_collider = math.max(widest_collider, unit_defs.collider_radius(def))
end

type Layer = {
	grid: flat_grid.Grid,
	-- the widest collider this layer can hold
	widest: number,
	ys: { number },
	half_heights: { number },
	entities: { Entity },
}

local function new_layer(cell: number, side: number, widest: number): Layer
	return { grid = flat_grid.new(cell, side), widest = widest, ys = {}, half_heights = {}, entities = {} }
end

local small_layer = new_layer(8, 256, SMALL_RADIUS)
local large_layer = new_layer(24, 64, widest_collider)
local wreck_layer = new_layer(24, 64, widest_collider)
local air_layer = new_layer(24, 64, widest_collider)
-- A blast reaching further than this many cells out on any side is wide enough that walking the grid
-- buys nothing (a nuke's, say), and just checks everything instead.
local MAX_BLAST_CELLS = 24

local function layer_add(layer: Layer, entity: Entity)
	local def = unit_defs.of(entity)
	local position = entity.position
	local k = flat_grid.add(layer.grid, position.X, position.Z, unit_defs.collider_radius(def))
	layer.ys[k] = position.Y
	layer.half_heights[k] = unit_defs.collider_height(def) / 2
	layer.entities[k] = entity
end

local function rebuild_grids()
	flat_grid.clear(small_layer.grid)
	flat_grid.clear(large_layer.grid)
	flat_grid.clear(wreck_layer.grid)
	flat_grid.clear(air_layer.grid)
	for _, entity in state.all() do
		-- a reclaimable is struck by nothing and hurt by no blast, so no shot looks for it
		if entity.alive == false or entity.kind == "reclaimable" then
			continue
		end
		if entity.kind == "wreck" then
			layer_add(wreck_layer, entity)
		elseif air.is_aircraft(entity) then
			layer_add(air_layer, entity)
		elseif unit_defs.collider_radius(unit_defs.of(entity)) <= SMALL_RADIUS then
			layer_add(small_layer, entity)
		else
			layer_add(large_layer, entity)
		end
	end
	for _, cargo in state.carried() do
		layer_add(air_layer, cargo)
	end
	flat_grid.sort(small_layer.grid)
	flat_grid.sort(large_layer.grid)
	flat_grid.sort(wreck_layer.grid)
	flat_grid.sort(air_layer.grid)
end

-- Calls `visit(entity, k)` with every entry of `layer` in a cell within `reach` of (x, z) on either
-- axis. `k` indexes the layer's arrays, for a caller that wants the numbers without the def lookups.
-- A visit that returns true ends the search there.
local function each_in_layer(layer: Layer, x: number, z: number, reach: number, visit: (Entity, number) -> boolean?)
	local grid = layer.grid
	local size, side = grid.size, grid.side
	local order, starts, stops, entities = grid.order, grid.starts, grid.stops, layer.entities
	for gx = math.floor((x - reach) / size), math.floor((x + reach) / size) do
		for gz = math.floor((z - reach) / size), math.floor((z + reach) / size) do
			local c = (gz % side) * side + (gx % side) + 1
			local first = starts[c]
			if first == 0 then
				continue
			end
			for s = first, stops[c] - 1 do
				local k = order[s]
				local entity = entities[k]
				if entity.alive and visit(entity, k) == true then
					return
				end
			end
		end
	end
end
-- A rocket that has flown this long is gone, whatever it hit.
local MAX_AGE = 30
-- What is left of a blast at its very edge, as a fraction of the damage at its centre.
local EDGE_DAMAGE = 0.25
-- Lobbed shells, and rockets that ask to, lead a moving target: the aim is refined this many times for where
-- it will be by the time the shell arrives.
local LEAD_ITERATIONS = 3
-- The most a bomb is pushed sideways onto its aim, in studs a second: BAR's one elmo a frame.
local BOMB_STEER = 30 / 11

local projectiles: { Projectile } = {}
local next_projectile_id = 1

-- A random direction within `half_angle` radians of `direction`.
local function strayed(direction: Vector3, half_angle: number): Vector3
	local axis = if math.abs(direction.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local right = direction:Cross(axis).Unit
	local up = right:Cross(direction)
	local around = math.random() * math.pi * 2
	local off = half_angle * math.random()
	return (direction * math.cos(off) + (right * math.cos(around) + up * math.sin(around)) * math.sin(off)).Unit
end

-- The sideways push a bomb let go from `origin` at `aim` is given, as BAR gives it, to make up for a bomber that is
-- not quite lined up on what it is bombing: whatever takes it from its bomber's line onto the aim by the time it
-- comes down, but no more than BOMB_STEER.
local function bomb_steer(owner: Entity, origin: Vector3, aim: Vector3, params: types.ProjectileParams): Vector3
	local along = Vector3.new(owner.velocity.X, 0, owner.velocity.Z)
	if along.Magnitude < 1e-3 then
		return Vector3.zero
	end
	along = along.Unit
	local offset = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
	local across = offset - along * offset:Dot(along)
	local steer = across / math.max(0.01, projectile_mod.fall_time(origin, owner.velocity, params.gravity, aim.Y))
	if steer.Magnitude > BOMB_STEER then
		steer = steer.Unit * BOMB_STEER
	end
	return steer
end

-- The enemy nuke an anti-nuke at `position` launches at, if there is one: as in BAR, one that is coming down within
-- its `coverage` (its weapon's range), wherever the nuke is now, and that no interceptor is chasing yet. The one that
-- will land nearest it goes first. A nuke still climbing out of its silo is left alone until it levels off at its
-- cruising height, so the interceptor meets it up there rather than over the silo it was fired from.
local function pick_nuke_target(position: Vector3, team: types.TeamId, coverage: number): Projectile?
	local nearest: Projectile? = nil
	local nearest_distance = coverage
	for _, projectile in projectiles do
		if
			projectile.is_nuclear
			and projectile.flight.phase ~= "climb"
			and projectile.chased_by == nil
			and projectile.intercepted == false
			and alliances.are_allied(projectile.team, team) == false
		then
			local distance = Vector2.new(projectile.aim.X - position.X, projectile.aim.Z - position.Z).Magnitude
			if distance <= nearest_distance then
				nearest = projectile
				nearest_distance = distance
			end
		end
	end
	return nearest
end

-- Fires a rocket from `origin` toward `aim`. A lobbed shell is angled to come down on `aim`, ahead of it
-- by however far `aim_velocity` says it will have gone by then. For homing projectiles, the target entity is needed.
-- It was fired `late` seconds ago, partway through the tick, so it leaves from where its owner was then and has
-- already flown that long.
local function launch(
	owner: Entity,
	origin: Vector3,
	aim: Vector3,
	weapon: types.Weapon,
	aim_velocity: Vector3?,
	target: Entity?,
	late: number
)
	local params = weapon.projectile
	if params == nil then
		return
	end
	origin -= owner.velocity * late

	-- an interceptor goes after one nuke, the one its anti-nuke picked (`pick_nuke_target`), and is aimed where it
	-- will meet it
	local nuke: Projectile? = nil
	if weapon.anti_nuke == true then
		nuke = pick_nuke_target(owner.position, owner.team, weapon.range)
		if nuke == nil then
			return
		end
		local at = nuke.flight.position
		aim = at + nuke.flight.velocity * projectile_mod.time_to_reach((at - origin).Magnitude, params)
	end

	local direction = aim - origin
	if params.arc ~= nil then
		local flight_time: number
		local speed: number
		direction, flight_time, speed = projectile_mod.aim(origin, aim, params)
		if aim_velocity ~= nil then
			local moving = Vector3.new(aim_velocity.X, 0, aim_velocity.Z)
			for _ = 1, LEAD_ITERATIONS do
				direction, flight_time, speed = projectile_mod.aim(origin, aim + moving * flight_time, params)
			end
		end
		-- a shell on the medium arc is launched slower than its weapon's full speed, and the client has to fly it the same
		if speed ~= params.speed then
			params = table.clone(params)
			params.speed = speed
		end
		if params.inaccuracy ~= nil then
			direction = strayed(direction, params.inaccuracy)
		end
	elseif params.dropped == true then
		-- a bomb goes down from wherever it is let go, whatever it was aimed at, and on at the speed it was going
		direction = Vector3.new(0, -1, 0)
	elseif params.leads == true and aim_velocity ~= nil then
		-- ahead of a moving target: the aim is refined for where it will be when the rocket arrives
		local intercept = aim
		for _ = 1, LEAD_ITERATIONS do
			intercept = aim + aim_velocity * projectile_mod.time_to_reach((intercept - origin).Magnitude, params)
		end
		direction = intercept - origin
	end
	if direction.Magnitude < 1e-3 then
		direction = Vector3.new(math.sin(owner.facing), 0, math.cos(owner.facing))
	end
	-- a straight shot, like a laser bolt, strays within its cone as a lobbed shell does
	if params.arc == nil and params.dropped ~= true and params.homing ~= true and params.inaccuracy ~= nil then
		direction = strayed(direction.Unit, params.inaccuracy)
	end
	-- an anti-air missile is guided for so long and no longer, and now and then is fired to just miss; the client has to
	-- know both to fly it the same
	if params.homing == true and weapon.anti_nuke ~= true then
		params = table.clone(params)
		if params.guidance_time == nil then
			params.guidance_time = projectile_mod.time_to_reach(weapon.range, params) * GUIDANCE_MARGIN
		end
		if target ~= nil and miss_roll:NextNumber() < config.HOMING_MISS_CHANCE then
			local target_def = unit_defs.of(target)
			local clear = math.max(unit_defs.collider_radius(target_def), unit_defs.collider_height(target_def) / 2)
				+ MISS_CLEARANCE
			local across = direction:Cross(Vector3.yAxis)
			across = if across.Magnitude > 1e-3 then across.Unit else Vector3.xAxis
			local around = miss_roll:NextNumber() * 2 * math.pi
			params.aim_offset = CFrame.fromAxisAngle(direction.Unit, around):VectorToWorldSpace(across) * clear
		end
	end

	local inherited: Vector3? = nil
	if params.dropped == true then
		inherited = owner.velocity + bomb_steer(owner, origin, aim, params)
	end

	local id = next_projectile_id
	next_projectile_id += 1
	local homing_entity_id = if weapon.anti_nuke ~= true
			and params.homing == true
			and target ~= nil
		then target.id
		else nil
	local flight = projectile_mod.launch(origin, direction, params, aim, inherited)
	if late > 0 then
		projectile_mod.step(flight, params, late)
	end
	if nuke ~= nil then
		nuke.chased_by = id
	end
	table.insert(projectiles, {
		id = id,
		owner_id = owner.id,
		team = owner.team,
		flight = flight,
		params = params,
		damage = weapon.damage,
		anti_air = weapon.anti_air == true,
		paralyze_time = weapon.paralyze_time,
		clear_of_owner = false,
		exempt = shields.covering(origin),
		is_nuclear = params.nuclear == true,
		aim = aim,
		chased_by = nil,
		intercepted = false,
		is_anti_nuke = weapon.anti_nuke == true,
		homing_target_id = if nuke ~= nil then nuke.id else nil,
		homing_entity_id = homing_entity_id,
		target_id = if target ~= nil then target.id else nil,
		pierce_wait = 0,
	})

	weapon_fired:FireAllClients({
		-- homing_target_id lets the client steer the projectile it draws the same way this one
		-- actually flies, instead of a plain ballistic path that happens to land where it should
		projectile = {
			id = id,
			from = origin,
			direction = direction.Unit,
			params = params,
			aim = aim,
			inherited = inherited,
			late = late,
			homing_target_id = homing_entity_id,
			-- and an interceptor, the nuke it chases
			homing_projectile_id = if nuke ~= nil then nuke.id else nil,
		},
		team = owner.team,
	})
end

-- Whether `at` is within `other`'s collider, the rocket's own thickness included.
local function inside(at: Vector3, other: Entity): boolean
	local def = unit_defs.of(other)
	local sideways = Vector2.new(at.X - other.position.X, at.Z - other.position.Z).Magnitude
	local vertical = math.abs(at.Y - other.position.Y)
	return sideways <= unit_defs.collider_radius(def) + PROJECTILE_RADIUS
		and vertical <= unit_defs.collider_height(def) / 2 + PROJECTILE_RADIUS
end

-- The first thing solid enough to stop the rocket where it is now. Its launcher does not count while the
-- rocket is still inside it, however big it is, but does once the rocket has come out and fallen back on it. A
-- missile that is still climbing or crossing is high over everything, and touches nothing until it dives.
-- Aircraft have no collider: the only one it can strike is the one it was fired at, and the same goes for what hangs
-- from a transport. A torpedo strikes only what is
-- in the water with it (`unit_defs.in_water`), and a ship's hull, which sits on the surface, reaches HULL_DRAFT
-- under it for one. A torpedo never strikes its own launcher.
local function struck_by(projectile: Projectile): Entity?
	if projectile.flight.phase == "climb" or projectile.flight.phase == "cruise" then
		return nil
	end
	local at = projectile.flight.position
	local ax, ay, az = at.X, at.Y, at.Z
	local torpedo = projectile.params.torpedo == true
	-- the launcher does not count until the rocket has been outside it at least once
	if projectile.clear_of_owner == false then
		local owner = state.get(projectile.owner_id)
		if owner == nil or inside(at, owner) == false then
			projectile.clear_of_owner = true
		end
	end
	local found: Entity? = nil
	local function visit_layer(layer: Layer)
		local xs, zs, rs = layer.grid.xs, layer.grid.zs, layer.grid.rs
		local ys, half_heights = layer.ys, layer.half_heights
		each_in_layer(layer, ax, az, layer.widest + PROJECTILE_RADIUS, function(other: Entity, k: number): boolean?
			local reach = rs[k] + PROJECTILE_RADIUS
			local ox, oz = ax - xs[k], az - zs[k]
			if ox * ox + oz * oz > reach * reach then
				return nil
			end
			if torpedo then
				local def = unit_defs.of(other)
				if unit_defs.in_water(def, other.position) == false then
					return nil
				end
				local draft = if unit_defs.floats(def) then HULL_DRAFT else 0
				local top = ys[k] + half_heights[k] + PROJECTILE_RADIUS
				local bottom = ys[k] - half_heights[k] - draft - PROJECTILE_RADIUS
				if ay > top or ay < bottom then
					return nil
				end
			elseif math.abs(ay - ys[k]) > half_heights[k] + PROJECTILE_RADIUS then
				return nil
			end
			if other.id == projectile.owner_id then
				-- a torpedo runs away level and never comes back down on its launcher; a ship's that is let go from
				-- the deck would otherwise meet its own keel as it drops into the water
				if projectile.clear_of_owner == false or torpedo then
					return nil
				end
			-- Don't let a direct hit strike a unit allied with the shooter (e.g. a bomber flying
			-- through its own swarm), matching the AoE splash's ally check below. The owner itself
			-- is still a valid strike (a rocket falling back onto its own launcher).
			elseif alliances.are_allied(other.team, projectile.team) then
				return nil
			end
			found = other
			return true
		end)
	end
	visit_layer(small_layer)
	if found == nil then
		visit_layer(large_layer)
	end
	if found == nil and projectile.target_id ~= nil then
		local target = state.find(projectile.target_id)
		if
			target ~= nil
			and (air.is_aircraft(target) or state.carrier_of(target.id) ~= nil)
			and alliances.are_allied(target.team, projectile.team) == false
			and inside(at, target)
		then
			found = target
		end
	end
	return found
end

-- What `amount` of the rocket's damage comes to against `target`: an aircraft takes only a fraction of it
-- unless the rocket was fired by a dedicated anti air weapon.
local function damage_to(projectile: Projectile, target: Entity, amount: number): number
	-- a wreck lies on the ground whatever it was, so it is not spared for having been an aircraft
	if target.kind == "wreck" then
		return amount
	end
	return unit_defs.damage_against(projectile.anti_air, unit_defs.of(target), amount)
end

-- The rocket goes off at `at`. What it struck takes the whole damage; everything else within the blast
-- takes less the further from the centre it is, friend and foe alike - except the shooter itself,
-- which its own blast never reaches. `through` says it is a piercing shot going off inside what it is going
-- through, and flies on.
local function detonate(
	projectile: Projectile,
	at: Vector3,
	struck: Entity?,
	apply_damage: (Entity, number, EntityId?, types.TeamId?, number?) -> (),
	through: boolean?
)
	weapon_fired:FireAllClients({
		impact = { id = projectile.id, at = at, radius = projectile.params.aoe_radius, through = through },
		team = projectile.team,
	})

	-- EMP leaves the ground as it was
	if projectile.paralyze_time == nil then
		deformation.crater(at, projectile.params.aoe_radius, projectile.damage)
	end

	if struck ~= nil then
		apply_damage(
			struck,
			damage_to(projectile, struck, projectile.damage),
			projectile.owner_id,
			projectile.team,
			projectile.paralyze_time
		)
	end
	local aoe = projectile.params.aoe_radius
	local edge = projectile.params.edge_effectiveness or EDGE_DAMAGE
	local function blast(other: Entity, reach: number, half_height: number)
		-- the shooter itself never takes its own blast - a bomber flying away from a bomb it just
		-- dropped, say - but nobody else is spared for being on its side: that stays real friendly fire, to
		-- the team's own things always, and to its allies' with ally griefing on (`alliances.may_harm`)
		if (struck ~= nil and other.id == struck.id) or other.id == projectile.owner_id then
			return
		end
		-- as in BAR, the blast is measured to the nearest point of the collider, not its centre: anything the
		-- blast touches at all is hurt, and something it lands right against takes it all
		local position = other.position
		local sideways = math.max(0, Vector2.new(position.X - at.X, position.Z - at.Z).Magnitude - reach)
		local vertical = math.max(0, math.abs(position.Y - at.Y) - half_height)
		local distance = math.sqrt(sideways * sideways + vertical * vertical)
		if distance <= aoe then
			local falloff = 1 - (1 - edge) * (if aoe > 0 then distance / aoe else 1)
			apply_damage(
				other,
				damage_to(projectile, other, projectile.damage * falloff),
				projectile.owner_id,
				projectile.team,
				projectile.paralyze_time
			)
		end
	end
	-- anything the blast reaches is within the blast plus its own radius of the centre, and so within that
	-- of it along both axes, which is all a layer is searched by
	if (aoe + widest_collider) / 8 > MAX_BLAST_CELLS then
		for _, group in { state.all(), state.carried() } do
			for _, other in group do
				if other.alive then
					local def = unit_defs.of(other)
					blast(other, unit_defs.collider_radius(def), unit_defs.collider_height(def) / 2)
				end
			end
		end
		return
	end
	for _, layer in { small_layer, large_layer, wreck_layer, air_layer } do
		local rs, half_heights = layer.grid.rs, layer.half_heights
		each_in_layer(layer, at.X, at.Z, aoe + layer.widest, function(other: Entity, k: number): boolean?
			blast(other, rs[k], half_heights[k])
			return nil
		end)
	end
end

-- Sets `projectile` off at `at` for show only: nothing is hurt and the ground is left as it was. An interceptor goes
-- off like this wherever it ends, and so does a nuke it catches, which is drawn going off in the air (`airburst`).
local function burst_harmlessly(projectile: Projectile, at: Vector3, airburst: boolean)
	weapon_fired:FireAllClients({
		impact = { id = projectile.id, at = at, radius = projectile.params.aoe_radius, airburst = airburst },
		team = projectile.team,
	})
end

-- The projectile in flight with the id `id`, if it is still flying.
local function in_flight_with(id: number): Projectile?
	for _, projectile in projectiles do
		if projectile.id == id and projectile.intercepted == false then
			return projectile
		end
	end
	return nil
end

-- Flies every rocket forward one tick. `apply_damage` is handed in rather than required, because combat
-- launches rockets and so depends on this module.
local function tick(delta: number, apply_damage: (Entity, number, EntityId?, types.TeamId?, number?) -> ())
	if #projectiles > 0 then
		rebuild_grids()
	end
	local index = 1
	while index <= #projectiles do
		local projectile = projectiles[index]

		-- a nuke an interceptor caught has already gone off, and only now leaves the list, so that taking it out did not
		-- throw off the walk through it
		if projectile.intercepted then
			table.remove(projectiles, index)
			continue
		end
		-- the nuke an interceptor chases; one whose nuke has come down some other way has nothing left to do
		local nuke: Projectile? = nil
		if projectile.is_anti_nuke then
			nuke = if projectile.homing_target_id ~= nil then in_flight_with(projectile.homing_target_id) else nil
			if nuke == nil then
				burst_harmlessly(projectile, projectile.flight.position, false)
				table.remove(projectiles, index)
				continue
			end
		end

		local steps = math.max(1, math.ceil(projectile.flight.velocity.Magnitude * delta / HIT_STEP))
		local sub_delta = delta / steps

		local finished = false
		for _ = 1, steps do
			-- homing logic: an interceptor steers toward the nuke it tracks, and an AA missile (or other non anti-nuke
			-- homing weapon) toward the entity it was fired at for as long as that entity is still alive
			if nuke ~= nil then
				projectile_mod.home(
					projectile.flight,
					projectile.params,
					nuke.flight.position,
					nuke.flight.velocity,
					sub_delta
				)
			end
			if projectile.homing_entity_id ~= nil then
				local target = state.find(projectile.homing_entity_id)
				if target ~= nil and target.alive then
					projectile_mod.home(
						projectile.flight,
						projectile.params,
						target.position,
						target.velocity,
						sub_delta
					)
				else
					projectile.homing_entity_id = nil
				end
			end

			projectile_mod.step(projectile.flight, projectile.params, sub_delta)
			local at = projectile.flight.position

			-- a plasma shell that runs into an enemy shield goes off on it, and does no harm
			if
				projectile.params.plasma == true
				and shields.absorb(at, projectile.damage, projectile.team, projectile.exempt)
			then
				weapon_fired:FireAllClients({
					impact = { id = projectile.id, at = at, radius = SHIELD_BURST_RADIUS },
					team = projectile.team,
				})
				finished = true
				break
			end

			-- An interceptor that reaches its nuke kills it, as in BAR one is all it takes. The nuke goes off there in the
			-- air, for show: the blast harms nothing, not even aircraft flying through it. An interceptor strikes
			-- nothing else, and harms nothing wherever it ends.
			if projectile.is_anti_nuke then
				if nuke ~= nil and (nuke.flight.position - at).Magnitude <= INTERCEPT_RADIUS then
					burst_harmlessly(nuke, nuke.flight.position, true)
					nuke.intercepted = true
					burst_harmlessly(projectile, at, false)
					finished = true
					break
				end
				local floor = math.max(heightmap.height_at(at.X, at.Z), config.WATER_LEVEL)
				if heightmap.in_bounds(at.X, at.Z) == false or at.Y <= floor or projectile.flight.age > MAX_AGE then
					-- the nuke it missed is free for another interceptor to go after
					if nuke ~= nil then
						nuke.chased_by = nil
					end
					burst_harmlessly(projectile, at, false)
					finished = true
					break
				end
				continue
			end

			local struck = struck_by(projectile)
			-- a piercing shot goes off inside what it strikes as often as Spring's would, and flies on through it
			if projectile.params.pierce == true then
				if struck == nil then
					projectile.pierce_wait = 0
				else
					projectile.pierce_wait -= sub_delta
					if projectile.pierce_wait <= 0 then
						detonate(projectile, at, struck, apply_damage, true)
						projectile.pierce_wait += PIERCE_INTERVAL
					end
					struck = nil
				end
			end
			if struck ~= nil then
				detonate(projectile, at, struck, apply_damage)
				finished = true
				break
			end
			-- it goes off on the ground, or on the sea's surface if it comes down over water; a torpedo is under that
			-- surface, and goes off only when it runs into the sea floor or the shore
			local floor = heightmap.height_at(at.X, at.Z)
			if projectile.params.torpedo ~= true then
				floor = math.max(floor, config.WATER_LEVEL)
			end
			if heightmap.in_bounds(at.X, at.Z) == false or at.Y <= floor then
				detonate(projectile, Vector3.new(at.X, floor, at.Z), nil, apply_damage)
				finished = true
				break
			end
			if
				projectile.flight.age > (if projectile.params.missile ~= nil then config.MISSILE_MAX_AGE else MAX_AGE)
			then
				detonate(projectile, at, nil, apply_damage)
				finished = true
				break
			end
		end

		if finished then
			table.remove(projectiles, index)
		else
			index += 1
		end
	end
end

-- Every rocket in flight, for a Studio test to watch (see studio_tests.luau). Nothing else reads it, and nothing
-- may change it.
local function in_flight(): { Projectile }
	return projectiles
end

-- Drops everything in flight without letting any of it land, for when the map is replaced under it.
local function clear()
	table.clear(projectiles)
end

return table.freeze({
	launch = launch,
	tick = tick,
	clear = clear,
	pick_nuke_target = pick_nuke_target,
	in_flight = in_flight,
})
