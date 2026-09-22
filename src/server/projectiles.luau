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
	-- whether it has come out of its launcher's collider yet; until it has, the launcher cannot be struck
	clear_of_owner: boolean,
	-- the shields it was fired from inside, which do not stop it
	exempt: { [EntityId]: boolean },
}

local weapon_fired: RemoteEvent = ReplicatedStorage.Shared.WeaponFired

-- Collisions are tested at least this often along the flight, so a fast rocket cannot skip through
-- something narrow.
local HIT_STEP = 0.5
-- How big the burst is where a shield swallows a shell.
local SHIELD_BURST_RADIUS = 3
-- The rocket's own thickness.
local ROCKET_RADIUS = 0.3
-- A rocket that has flown this long is gone, whatever it hit.
local MAX_AGE = 30
-- What is left of a blast at its very edge, as a fraction of the damage at its centre.
local EDGE_DAMAGE = 0.25
-- Lobbed shells, and rockets that ask to, lead a moving target: the aim is refined this many times for where
-- it will be by the time the shell arrives.
local LEAD_ITERATIONS = 3

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

-- Fires a rocket from `origin` toward `aim`. A lobbed shell is angled to come down on `aim`, ahead of it
-- by however far `aim_velocity` says it will have gone by then.
local function launch(owner: Entity, origin: Vector3, aim: Vector3, weapon: types.Weapon, aim_velocity: Vector3?)
	local params = weapon.projectile
	if params == nil then
		return
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
		-- a bomb goes down from wherever it is let go, whatever it was aimed at
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

	local id = next_projectile_id
	next_projectile_id += 1
	table.insert(projectiles, {
		id = id,
		owner_id = owner.id,
		team = owner.team,
		flight = projectile_mod.launch(origin, direction, params, aim),
		params = params,
		damage = weapon.damage,
		anti_air = weapon.anti_air == true,
		clear_of_owner = false,
		exempt = shields.covering(origin),
	})

	weapon_fired:FireAllClients({
		rocket = { id = id, from = origin, direction = direction.Unit, params = params, aim = aim },
		team = owner.team,
	})
end

-- Whether `at` is within `other`'s collider, the rocket's own thickness included.
local function inside(at: Vector3, other: Entity): boolean
	local def = unit_defs.get(other.def_name)
	local sideways = Vector2.new(at.X - other.position.X, at.Z - other.position.Z).Magnitude
	local vertical = math.abs(at.Y - other.position.Y)
	return sideways <= unit_defs.collider_radius(def) + ROCKET_RADIUS
		and vertical <= unit_defs.collider_height(def) / 2 + ROCKET_RADIUS
end

-- The first thing solid enough to stop the rocket where it is now. Its launcher does not count while the
-- rocket is still inside it, however big it is, but does once the rocket has come out and fallen back on it. A
-- missile that is still climbing or crossing is high over everything, and touches nothing until it dives.
local function struck_by(projectile: Projectile): Entity?
	if projectile.flight.phase == "climb" or projectile.flight.phase == "cruise" then
		return nil
	end
	local at = projectile.flight.position
	for _, other in state.all() do
		if other.alive == false or other.kind == "wreck" then
			continue
		end
		local touching = inside(at, other)
		if other.id == projectile.owner_id then
			if touching == false then
				projectile.clear_of_owner = true
			elseif projectile.clear_of_owner == false then
				continue
			end
		end
		if touching then
			return other
		end
	end
	return nil
end

-- What `amount` of the rocket's damage comes to against `target`: an aircraft takes only a fraction of it
-- unless the rocket was fired by a dedicated anti air weapon.
local function damage_to(projectile: Projectile, target: Entity, amount: number): number
	-- a wreck lies on the ground whatever it was, so it is not spared for having been an aircraft
	if target.kind == "wreck" then
		return amount
	end
	return unit_defs.damage_against(projectile.anti_air, unit_defs.get(target.def_name), amount)
end

-- The rocket goes off at `at`. What it struck takes the whole damage; everything else within the blast
-- takes less the further from the centre it is, friend and foe alike.
local function detonate(projectile: Projectile, at: Vector3, struck: Entity?, apply_damage: (Entity, number) -> ())
	weapon_fired:FireAllClients({
		impact = { id = projectile.id, at = at, radius = projectile.params.aoe_radius },
		team = projectile.team,
	})

	deformation.crater(at, projectile.params.aoe_radius, projectile.damage)

	if struck ~= nil then
		apply_damage(struck, damage_to(projectile, struck, projectile.damage))
	end
	for _, other in state.all() do
		if other.alive == false or (struck ~= nil and other.id == struck.id) then
			continue
		end
		local reach = unit_defs.collider_radius(unit_defs.get(other.def_name))
		local distance = (other.position - at).Magnitude
		if distance <= projectile.params.aoe_radius + reach then
			local edge = projectile.params.edge_effectiveness or EDGE_DAMAGE
			local falloff = 1 - (1 - edge) * math.clamp(distance / projectile.params.aoe_radius, 0, 1)
			apply_damage(other, damage_to(projectile, other, projectile.damage * falloff))
		end
	end
end

-- Flies every rocket forward one tick. `apply_damage` is handed in rather than required, because combat
-- launches rockets and so depends on this module.
local function tick(delta: number, apply_damage: (Entity, number) -> ())
	local index = 1
	while index <= #projectiles do
		local projectile = projectiles[index]
		local steps = math.max(1, math.ceil(projectile.flight.velocity.Magnitude * delta / HIT_STEP))
		local sub_delta = delta / steps

		local finished = false
		for _ = 1, steps do
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

			local struck = struck_by(projectile)
			if struck ~= nil then
				detonate(projectile, at, struck, apply_damage)
				finished = true
				break
			end
			-- it goes off on the ground, or on the sea's surface if it comes down over water
			local floor = math.max(heightmap.height_at(at.X, at.Z), config.WATER_LEVEL)
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

return table.freeze({
	launch = launch,
	tick = tick,
})
