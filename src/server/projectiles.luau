-- Rockets in flight. A rocket is launched along a line at where its target was, flies the shared
-- projectile model (thrust, then drag and gravity), and explodes on the first solid thing it touches or
-- on the ground. It flies through its own side's things and its allies', so a rocket fired past a friend
-- goes on by (a bomber's bombs fall through its own swarm), but its blast spares nobody but its shooter:
-- a friend standing by what it strikes is caught in it. Anti-nuke interceptors are projectiles of their own kind, which
-- strike nothing but the nuke they chase (server/interceptors.luau); what they need of a nuke is kept here, behind
-- `is_free_nuke`, `claim_nuke`, `free_nuke` and `catch_nuke`.
--
-- Clients are told about launches and impacts (shared/shot_events) and fly the same model themselves.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile_mod = require(ReplicatedStorage.Shared.projectile)
local weapon_kinds = require(ReplicatedStorage.Shared.weapon_kinds)
local shot_events = require(ReplicatedStorage.Shared.shot_events)

local state = require(script.Parent.state)
local deformation = require(script.Parent.deformation)
local shields = require(script.Parent.shields)
local alliances = require(script.Parent.alliances)
local spatial = require(script.Parent.spatial)
local rng = require(script.Parent.rng)
local damage = require(script.Parent.damage)
local sight = require(script.Parent.sight)
local shot_feed = require(script.Parent.shot_feed)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type EntityId = types.EntityId

-- The weapon a shot is from, as the clients know it (shot_events.Fired), and whether it is one of the shots that
-- weapon's shell split into (`types.Split`).
type Source = {
	def_name: string,
	skin: string?,
	weapon: number,
	split: boolean?,
}

-- What a nuclear missile has for interceptors (server/interceptors.luau): where it will come down, which is what an
-- anti-nuke's coverage is about; the interceptor sent after it, so that no other is spent on it (`claim_nuke`); and that
-- one has caught it (`catch_nuke`): it has gone off in the air, and is taken out on its own turn.
export type Nuke = {
	aim: Vector3,
	chased_by: number?,
	intercepted: boolean,
}

-- One shot in flight: what it is (its weapon's delivery, damage and kind, for all of its flight) and how its flight is
-- going (`flight`, and the rest of what changes as it flies).
export type Projectile = {
	id: number,
	-- whether it is still in the air: false once it has gone off, or been taken out of the air in any other way
	flying: boolean,
	owner_id: EntityId,
	team: types.TeamId,
	flight: projectile_mod.Flight,
	-- the weapon that fired it, whose harm it lands (`damage.hit`), and which one that is, as the clients know it
	weapon: types.Weapon,
	fired: Source,
	-- how it flies, its weapon's
	delivery: types.ProjectileDelivery,
	-- whether it has come out of its launcher's collider yet; until it has, the launcher cannot be struck
	clear_of_owner: boolean,
	-- the shields it was fired from inside, which do not stop it
	exempt: { [EntityId]: boolean },
	-- for a nuclear missile (`weapon_kinds`' `nuclear`), what interceptors need of it
	nuke: Nuke?,
	-- the entity a homing missile, such as an AA missile, tracks onto, while it lives
	homing_entity_id: EntityId?,
	-- what it was fired at, if it was fired at something: the one aircraft it can strike
	target_id: EntityId?,
	-- whether it goes through what it strikes (`weapon_kinds`' `pierces`), and if so how long until it goes off again
	-- inside what it is going through; nothing while it is in the clear, so it goes off the moment it strikes something
	pierces: boolean,
	pierce_wait: number,
	-- whether a plasma deflector stops it (`weapon_kinds`' `plasma`)
	is_plasma: boolean,
}

-- Collisions are tested at least this often along the flight, so a fast rocket cannot skip through
-- something narrow.
local HIT_STEP = 0.5
-- A homing projectile whose weapon does not give it a guidance time is guided for this many times as long as it
-- takes to fly its weapon's range: long enough to come round once for something that got past it, not long enough
-- to chase it for ever.
local GUIDANCE_MARGIN = 2.5
-- How far clear of its target's collider a missile fired to miss (shared/projectile.luau's HOMING_MISS_CHANCE) passes.
local MISS_CLEARANCE = 1.5
-- How big the burst is where a shield swallows a shell.
local SHIELD_BURST_RADIUS = 3
-- How big the puff is where a shell splits (`types.Split`), which harms nothing.
local SPLIT_BURST_RADIUS = 2
-- How hard a split shell's shots are pushed apart, as fractions of its speed: BAR's split effect adds, to each of the
-- three parts of the shell's velocity, up to 100/880 of its speed across and 100/440 of it up or down, in steps of a
-- hundredth.
local SPLIT_SPREAD_ACROSS = 1 / 880
local SPLIT_SPREAD_UP = 1 / 440
-- The projectile's own thickness.
local PROJECTILE_RADIUS = 0.3
-- How far under the surface a ship's hull reaches, for a torpedo: a ship rests on the water with nothing of its
-- collider below it, but a torpedo running under it has to meet its keel.
local HULL_DRAFT = 1.5
-- How often a piercing shot goes off while inside something: every frame of Spring's, where a `noexplode` projectile
-- collides, and so goes off, on every frame it overlaps a unit.
local PIERCE_INTERVAL = 1 / 30

-- Lobbed shells, and rockets that ask to, lead a moving target: the aim is refined this many times for where
-- it will be by the time the shell arrives.
local LEAD_ITERATIONS = 3
-- The most a bomb is pushed sideways onto its aim, in studs a second: BAR's one elmo a frame.
local BOMB_STEER = 30 / 11

local projectiles: { Projectile } = {}
-- The nuclear missiles among them, in the same order, for interceptors to look through (`nukes`).
local nuke_list: { Projectile } = {}
local next_projectile_id = 1

-- A new projectile's id: one sequence for every kind, which the clients know them all by.
local function new_id(): number
	local id = next_projectile_id
	next_projectile_id += 1
	return id
end

-- How many steps `flight` is flown in over `delta` seconds, and how long each is: short enough that it is tested
-- against what it could strike at least every HIT_STEP along the way.
local function substeps(flight: projectile_mod.Flight, delta: number): (number, number)
	local steps = math.max(1, math.ceil(flight.velocity.Magnitude * delta / HIT_STEP))
	return steps, delta / steps
end

-- A random direction within `half_angle` radians of `direction`.
local function strayed(direction: Vector3, half_angle: number): Vector3
	local axis = if math.abs(direction.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local right = direction:Cross(axis).Unit
	local up = right:Cross(direction)
	local random = rng.stream "projectiles"
	local around = random:NextNumber() * math.pi * 2
	local off = half_angle * random:NextNumber()
	return (direction * math.cos(off) + (right * math.cos(around) + up * math.sin(around)) * math.sin(off)).Unit
end

-- `direction`, or the way `owner` faces when it is next to nothing, as it is for a shot at something right on top of it.
local function or_facing(direction: Vector3, owner: Entity): Vector3
	if direction.Magnitude < 1e-3 then
		return Vector3.new(math.sin(owner.facing), 0, math.cos(owner.facing))
	end
	return direction
end

-- How a shot leaves its launcher: the way it is fired, what it is launched with beyond its weapon's params
-- (`projectile.Shot`), and the velocity it is let go with on top of that, for a bomb.
type Release = {
	direction: Vector3,
	shot: projectile_mod.Shot,
	inherited: Vector3?,
}

-- A lobbed shell is angled to come down on `aim`, ahead of it by however far `aim_velocity` says it will have gone by
-- then, along `arc` (shot_rules' `chosen_arc`, or its own). A shell on the medium arc is launched slower than its
-- weapon's full speed, and the client has to fly it the same.
local function aim_lobbed(
	delivery: types.LobbedDelivery,
	origin: Vector3,
	aim: Vector3,
	aim_velocity: Vector3,
	arc: types.Arc?
): Release
	local params = delivery.projectile
	local shell_arc = arc or delivery.arc
	local direction, flight_time, speed = projectile_mod.aim(origin, aim, params, shell_arc)
	local moving = Vector3.new(aim_velocity.X, 0, aim_velocity.Z)
	for _ = 1, LEAD_ITERATIONS do
		direction, flight_time, speed = projectile_mod.aim(origin, aim + moving * flight_time, params, shell_arc)
	end
	if params.inaccuracy ~= nil then
		direction = strayed(direction, params.inaccuracy)
	end
	local fuse = if params.burst_at_aim == true then flight_time else nil
	return { direction = direction, shot = { speed = speed, fuse = fuse }, inherited = nil }
end

-- A bomb goes down from wherever it is let go, whatever it was aimed at, and on at the speed it was going, pushed
-- sideways onto `aim` as BAR pushes it, to make up for a bomber not quite lined up on it: whatever takes it from its
-- bomber's line onto the aim by the time it comes down, but no more than BOMB_STEER.
local function aim_bomb(delivery: types.BombDelivery, owner: Entity, origin: Vector3, aim: Vector3): Release
	local params = delivery.projectile
	local steer = Vector3.zero
	local along = Vector3.new(owner.velocity.X, 0, owner.velocity.Z)
	if along.Magnitude >= 1e-3 then
		along = along.Unit
		local offset = Vector3.new(aim.X - origin.X, 0, aim.Z - origin.Z)
		local across = offset - along * offset:Dot(along)
		steer = across / math.max(0.01, projectile_mod.fall_time(origin, owner.velocity, params.gravity, aim.Y))
		if steer.Magnitude > BOMB_STEER then
			steer = steer.Unit * BOMB_STEER
		end
	end
	return { direction = Vector3.new(0, -1, 0), shot = { speed = params.speed }, inherited = owner.velocity + steer }
end

-- Anything else, `params`' shot guided as `guidance` says, is fired along a line at `aim`, or for one that leads,
-- ahead of it at where something moving at `aim_velocity` will be when it gets there, and strays within its cone. A
-- homing one does not stray but is guided (`guide`). A missile goes up whatever it is aimed along, and comes down on
-- `aim`.
local function aim_line(
	params: types.ProjectileParams,
	guidance: types.Guidance,
	owner: Entity,
	origin: Vector3,
	aim: Vector3,
	aim_velocity: Vector3
): Release
	local direction = aim - origin
	if guidance == "leads" then
		local intercept = aim
		for _ = 1, LEAD_ITERATIONS do
			intercept = aim + aim_velocity * projectile_mod.time_to_reach((intercept - origin).Magnitude, params)
		end
		direction = intercept - origin
	end
	direction = or_facing(direction, owner)
	if guidance ~= "homes" and params.inaccuracy ~= nil then
		direction = strayed(direction.Unit, params.inaccuracy)
	end
	return { direction = direction, shot = { speed = params.speed }, inherited = nil }
end

-- Readies `release`, a homing shot of `weapon`'s, of `delivery`, from `origin` at `aim`, for its flight, which the
-- client has to know to fly it the same: how long it is guided for, and no longer (its delivery's `guidance_time`, or
-- GUIDANCE_MARGIN times as long as it takes to fly its range); how high it is lofted over its target at first, and
-- launched toward (`StraightDelivery.loft`); and now and then, when it was fired at something, that it is to just miss
-- that.
local function guide(
	release: Release,
	weapon: types.Weapon,
	delivery: types.StraightDelivery | types.TorpedoDelivery,
	origin: Vector3,
	aim: Vector3,
	target: Entity?
)
	local params = delivery.projectile
	local shot = release.shot
	shot.guidance_time = delivery.guidance_time or projectile_mod.time_to_reach(weapon.range, params) * GUIDANCE_MARGIN
	if delivery.kind == "straight" and delivery.loft ~= nil then
		local loft = delivery.loft
		local distance = (aim - origin).Magnitude
		local loft_height = loft * distance
		shot.loft_height = loft_height
		shot.loft_time = projectile_mod.time_to_reach(distance, params)
		release.direction = aim + Vector3.new(0, loft_height, 0) - origin
	end
	if target ~= nil and rng.stream("projectiles"):NextNumber() < projectile_mod.HOMING_MISS_CHANCE then
		local target_def = target.def
		local clear = math.max(unit_defs.collider_radius(target_def), unit_defs.collider_height(target_def) / 2)
			+ MISS_CLEARANCE
		local direction = release.direction
		local across = direction:Cross(Vector3.yAxis)
		across = if across.Magnitude > 1e-3 then across.Unit else Vector3.xAxis
		local around = rng.stream("projectiles"):NextNumber() * 2 * math.pi
		-- `across` turned `around` about the line of flight (Rodrigues' formula, in Vector3 arithmetic rather than a
		-- CFrame, which the headless arena cannot match to the last bit)
		local k = direction.Unit
		local cos, sin = math.cos(around), math.sin(around)
		local turned = across * cos + k:Cross(across) * sin + k * (k:Dot(across) * (1 - cos))
		shot.aim_offset = turned * clear
	end
end

-- Where a shot of weapon `index` of `owner`'s leaves from, `late` seconds into its flight already: where its muzzle
-- was that long ago, partway through the tick, when the weapon was ready.
local function launch_point(owner: Entity, origin: Vector3, late: number): Vector3
	return origin - owner.velocity * late
end

-- Puts a shot of `weapon`, which is `fired`, in the air from `origin` as `release` says, toward `aim`, `late` seconds
-- into its flight already, and tells the clients, who fly it the same from the same (shot_events): they know its
-- weapon by `fired`, and steer it onto the entity `homing_target_id` or the projectile `homing_projectile_id` as this
-- one is. Its id and its flight, for whoever keeps it.
local function send_shot(
	fired: Source,
	weapon: types.Weapon,
	origin: Vector3,
	release: Release,
	aim: Vector3,
	late: number,
	homing_target_id: EntityId?,
	homing_projectile_id: number?
): (number, projectile_mod.Flight)
	local delivery = weapon.delivery
	assert(delivery.kind ~= "beam", "a beam launches no projectile")
	local id = new_id()
	local flight = projectile_mod.launch(origin, release.direction, delivery, release.shot, aim, release.inherited)
	if late > 0 then
		projectile_mod.step(flight, delivery, late)
	end
	shot_feed.send({
		kind = "projectile",
		id = id,
		def_name = fired.def_name,
		skin = fired.skin,
		weapon = fired.weapon,
		split = fired.split,
		from = origin,
		direction = release.direction.Unit,
		shot = release.shot,
		aim = aim,
		inherited = release.inherited,
		late = late,
		homing_target_id = homing_target_id,
		homing_projectile_id = homing_projectile_id,
	})
	return id, flight
end

-- The same for a shot of weapon `index` of `owner`'s, `weapon`.
local function release_shot(
	owner: Entity,
	weapon: types.Weapon,
	index: number,
	origin: Vector3,
	release: Release,
	aim: Vector3,
	late: number,
	homing_target_id: EntityId?,
	homing_projectile_id: number?
): (number, projectile_mod.Flight)
	local fired: Source = { def_name = owner.def_name, skin = owner.skin, weapon = index }
	return send_shot(fired, weapon, origin, release, aim, late, homing_target_id, homing_projectile_id)
end

-- Fires a shot of weapon `index` of `owner`'s, `weapon`, whose delivery launches a projectile, from `origin` at `aim`,
-- along `arc` for a lobbed shell (shot_rules' `chosen_arc`). It was fired `late` seconds ago, partway through the tick,
-- so it leaves from where its owner was then and has already flown that long. What differs from one shot to the next
-- is worked out here, as its delivery aims it (`Release`); the weapon's params are the same for every shot.
local function launch(
	owner: Entity,
	weapon: types.Weapon,
	index: number,
	origin: Vector3,
	aim: sight.Aim,
	arc: types.Arc?,
	late: number
)
	local delivery = weapon.delivery
	assert(delivery.kind ~= "beam", "a beam launches no projectile")
	local kind = weapon_kinds.get(weapon.kind)
	local at = sight.position_of(aim)
	local target = sight.target_of(aim)
	origin = launch_point(owner, origin, late)

	local release: Release
	local homing = false
	if delivery.kind == "lobbed" then
		release = aim_lobbed(delivery, origin, at, sight.velocity_of(aim), arc)
		release.direction = or_facing(release.direction, owner)
	elseif delivery.kind == "bomb" then
		release = aim_bomb(delivery, owner, origin, at)
	elseif delivery.kind == "missile" then
		release = aim_line(delivery.projectile, "none", owner, origin, at, sight.velocity_of(aim))
	else
		release = aim_line(delivery.projectile, delivery.guidance, owner, origin, at, sight.velocity_of(aim))
		homing = delivery.guidance == "homes"
		if homing then
			guide(release, weapon, delivery, origin, at, target)
		end
	end

	local homing_entity_id = if homing and target ~= nil then target.id else nil
	local fired: Source = { def_name = owner.def_name, skin = owner.skin, weapon = index }
	local id, flight = send_shot(fired, weapon, origin, release, at, late, homing_entity_id, nil)
	local projectile: Projectile = {
		id = id,
		flying = true,
		owner_id = owner.id,
		team = owner.team,
		flight = flight,
		weapon = weapon,
		fired = fired,
		delivery = delivery,
		clear_of_owner = false,
		exempt = shields.covering(origin),
		nuke = if kind.nuclear == true then { aim = at, chased_by = nil, intercepted = false } else nil,
		homing_entity_id = homing_entity_id,
		target_id = if target ~= nil then target.id else nil,
		pierces = kind.pierces == true,
		pierce_wait = 0,
		is_plasma = kind.plasma == true,
	}
	table.insert(projectiles, projectile)
	if projectile.nuke ~= nil then
		table.insert(nuke_list, projectile)
	end
end

-- Whether `at` is within `other`'s collider, the rocket's own thickness included.
local function inside(at: Vector3, other: Entity): boolean
	local def = other.def
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
	local torpedo = projectile.delivery.kind == "torpedo"
	-- the launcher does not count until the rocket has been outside it at least once
	if projectile.clear_of_owner == false then
		local owner = state.get(projectile.owner_id)
		if owner == nil or inside(at, owner) == false then
			projectile.clear_of_owner = true
		end
	end
	local found: Entity? = nil
	local function visit_layer(layer: spatial.Layer)
		local xs, zs, rs = layer.grid.xs, layer.grid.zs, layer.grid.rs
		local ys, half_heights = layer.ys, layer.half_heights
		spatial.each_in(layer, ax, az, layer.widest + PROJECTILE_RADIUS, function(other: Entity, k: number): boolean?
			local reach = rs[k] + PROJECTILE_RADIUS
			local ox, oz = ax - xs[k], az - zs[k]
			if ox * ox + oz * oz > reach * reach then
				return nil
			end
			if torpedo then
				local def = other.def
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
			-- it flies through its own side's things and its allies' (a bomber's bombs through its own swarm), though
			-- not its launcher, which it can come back down on
			elseif alliances.are_allied(other.team, projectile.team) then
				return nil
			end
			found = other
			return true
		end)
	end
	local layers = spatial.colliders()
	visit_layer(layers.small)
	if found == nil then
		visit_layer(layers.large)
	end
	if found == nil and projectile.target_id ~= nil then
		local target = state.get(projectile.target_id, true)
		if
			target ~= nil
			and (unit_defs.is_air(target.def) or state.carrier_of(target.id) ~= nil)
			and alliances.are_allied(target.team, projectile.team) == false
			and inside(at, target)
		then
			found = target
		end
	end
	return found
end

-- `amount` of `projectile`'s harm comes to `target`, which it struck `direct`ly or caught in its blast, less what a
-- shield round `target` that blocks everything takes of it.
local function strike(projectile: Projectile, target: Entity, amount: number, direct: boolean)
	local left = shields.shelter(target, amount, projectile.team, projectile.exempt)
	if left > 0 then
		damage.hit(target, left, projectile.weapon, projectile.owner_id, projectile.team, direct)
	end
end

-- The rocket goes off at `at`. What it struck takes the whole damage; everything else within the blast
-- takes less the further from the centre it is, friend and foe alike - except the shooter itself,
-- which its own blast never reaches. `through` says it is a piercing shot going off inside what it is going
-- through, and flies on.
local function detonate(projectile: Projectile, at: Vector3, struck: Entity?, through: boolean)
	shot_feed.send({
		kind = "impact",
		id = projectile.id,
		at = at,
		radius = projectile.delivery.projectile.aoe_radius,
		how = if through then "through" else "burst",
	})

	local amount = projectile.weapon.damage
	-- EMP leaves the ground as it was
	if projectile.weapon.paralyze_time == nil then
		deformation.crater(at, projectile.delivery.projectile.aoe_radius, amount)
	end

	if struck ~= nil then
		strike(projectile, struck, amount, true)
	end
	local params = projectile.delivery.projectile
	damage.blast(at, params.aoe_radius, params.edge_effectiveness, function(other: Entity, force: number)
		-- the shooter itself never takes its own blast - a bomber flying away from a bomb it just
		-- dropped, say - but nobody else is spared for being on its side: that stays real friendly fire, to
		-- the team's own things always, and to its allies' with ally griefing on (`alliances.may_harm`)
		if (struck ~= nil and other.id == struck.id) or other.id == projectile.owner_id then
			return
		end
		strike(projectile, other, amount * force, false)
	end)
end

-- Sets projectile `id` off at `at`, a blast `radius` wide, for show only: nothing is hurt and the ground is left as it
-- was. A shell a shield swallows goes off like this, an interceptor wherever it ends, and a nuke it catches, which is
-- drawn going off in the air (`airburst`).
local function burst_harmlessly(id: number, at: Vector3, radius: number, how: shot_events.ImpactHow)
	shot_feed.send({ kind = "impact", id = id, at = at, radius = radius, how = how })
end

-- Bursts `shell`, whose weapon splits (`types.Split`), into its shots where it is now, `late` seconds before the end of
-- the tick: each flies on from there with the shell's velocity and a random push of its own, as BAR's split effect
-- has it. The shell itself goes off harmlessly. The shots, to join the list once this tick's walk through it is done.
local function split_shell(shell: Projectile, split: types.Split, late: number): { Projectile }
	local flight = shell.flight
	local at = flight.position
	burst_harmlessly(shell.id, at, SPLIT_BURST_RADIUS, "burst")

	local weapon = split.weapon
	local delivery = weapon.delivery
	assert(delivery.kind ~= "beam", "a shell splits into projectiles")
	local kind = weapon_kinds.get(weapon.kind)
	local fired: Source =
		{ def_name = shell.fired.def_name, skin = shell.fired.skin, weapon = shell.fired.weapon, split = true }
	local speed = flight.velocity.Magnitude
	local random = rng.stream "projectiles"
	local shots: { Projectile } = {}
	for _ = 1, split.count do
		local push = Vector3.new(
			random:NextInteger(-100, 100) * SPLIT_SPREAD_ACROSS,
			random:NextInteger(-100, 100) * SPLIT_SPREAD_UP,
			random:NextInteger(-100, 100) * SPLIT_SPREAD_ACROSS
		)
		local velocity = flight.velocity + push * speed
		local release: Release = { direction = velocity.Unit, shot = { speed = velocity.Magnitude }, inherited = nil }
		local id, shot_flight = send_shot(fired, weapon, at, release, at, late, nil, nil)
		table.insert(shots, {
			id = id,
			flying = true,
			owner_id = shell.owner_id,
			team = shell.team,
			flight = shot_flight,
			weapon = weapon,
			fired = fired,
			delivery = delivery,
			clear_of_owner = true,
			exempt = shell.exempt,
			nuke = nil,
			homing_entity_id = nil,
			target_id = nil,
			pierces = kind.pierces == true,
			pierce_wait = 0,
			is_plasma = kind.plasma == true,
		})
	end
	return shots
end

-- Every nuclear missile in the air, in the order they were launched, for interceptors to choose from. Read only.
local function nukes(): { Projectile }
	return nuke_list
end

-- Whether `nuke`, a nuclear missile, is still in the air, uncaught, with no interceptor after it yet.
local function is_free_nuke(nuke: Projectile): boolean
	local record = nuke.nuke
	return nuke.flying and record ~= nil and record.chased_by == nil and record.intercepted == false
end

-- The interceptor `interceptor_id` goes after `nuke`, which no other interceptor will now (`is_free_nuke`).
local function claim_nuke(nuke: Projectile, interceptor_id: number)
	local record = nuke.nuke
	assert(record ~= nil and is_free_nuke(nuke), "an interceptor goes after a nuke nothing is after yet")
	record.chased_by = interceptor_id
end

-- The interceptor after `nuke` has come down without catching it, which leaves it free for another to go after.
local function free_nuke(nuke: Projectile)
	local record = nuke.nuke
	if record ~= nil then
		record.chased_by = nil
	end
end

-- `nuke` is caught: it goes off high in the air, for show, harming nothing, and is gone.
local function catch_nuke(nuke: Projectile)
	local record = nuke.nuke
	if record == nil or record.intercepted then
		return
	end
	record.intercepted = true
	burst_harmlessly(nuke.id, nuke.flight.position, nuke.delivery.projectile.aoe_radius, "airburst")
end

-- Whether `projectile` is still in the air: not gone off, and not caught.
local function in_the_air(projectile: Projectile): boolean
	return projectile.flying and (projectile.nuke == nil or projectile.nuke.intercepted == false)
end

-- Takes `projectile`, which is at `index` in the list, out of the air.
local function remove(index: number)
	local projectile = table.remove(projectiles, index) :: Projectile
	projectile.flying = false
	if projectile.nuke ~= nil then
		table.remove(nuke_list, table.find(nuke_list, projectile) :: number)
	end
end

-- Flies every rocket forward one tick.
local function tick(delta: number)
	-- the shots of shells that split this tick, which are already as far along as they are to be at its end
	local split_shots: { Projectile } = {}
	local index = 1
	while index <= #projectiles do
		local projectile = projectiles[index]

		-- a nuke an interceptor caught has already gone off, and only now leaves the list, so that taking it out did not
		-- throw off the walk through it
		if projectile.nuke ~= nil and projectile.nuke.intercepted then
			remove(index)
			continue
		end

		local steps, sub_delta = substeps(projectile.flight, delta)

		local finished = false
		for step = 1, steps do
			-- a homing missile, such as an AA missile, steers toward the entity it was fired at for as long as that entity
			-- is still alive
			if projectile.homing_entity_id ~= nil then
				local target = state.get(projectile.homing_entity_id, true)
				if target ~= nil then
					projectile_mod.home(
						projectile.flight,
						projectile.delivery.projectile,
						target.position,
						target.velocity,
						sub_delta
					)
				else
					projectile.homing_entity_id = nil
				end
			end

			projectile_mod.step(projectile.flight, projectile.delivery, sub_delta)
			local at = projectile.flight.position

			-- a plasma shell that runs into an enemy plasma deflector goes off on it, and does no harm
			if
				projectile.is_plasma
				and shields.absorb(at, projectile.weapon.damage, projectile.team, projectile.exempt)
			then
				burst_harmlessly(projectile.id, at, SHIELD_BURST_RADIUS, "burst")
				finished = true
				break
			end

			local struck = struck_by(projectile)
			-- a piercing shot goes off inside what it strikes as often as Spring's would, and flies on through it
			if projectile.pierces then
				if struck == nil then
					projectile.pierce_wait = 0
				else
					projectile.pierce_wait -= sub_delta
					if projectile.pierce_wait <= 0 then
						detonate(projectile, at, struck, true)
						projectile.pierce_wait += PIERCE_INTERVAL
					end
					struck = nil
				end
			end
			if struck ~= nil then
				detonate(projectile, at, struck, false)
				finished = true
				break
			end
			-- it goes off on the ground, or on the sea's surface if it comes down over water; a torpedo is under that
			-- surface, and goes off only when it runs into the sea floor or the shore. A missile climbing straight up
			-- is stopped by nothing, the surface included, so one launched from a submarine rises out of the sea.
			local floor = heightmap.height_at(at.X, at.Z)
			if projectile.delivery.kind ~= "torpedo" then
				floor = math.max(floor, ground_levels.WATER_LEVEL)
			end
			local climbing = projectile.flight.phase == "climb"
			if heightmap.in_bounds(at.X, at.Z) == false or (at.Y <= floor and climbing == false) then
				detonate(projectile, Vector3.new(at.X, floor, at.Z), nil, false)
				finished = true
				break
			end
			-- a shell with a fuse goes off where it is once its time is up, in the air or not: its weapon's
			-- (ProjectileParams.fuse), or its own, for one that bursts where it was aimed (`burst_at_aim`)
			local fuse = projectile.flight.shot.fuse or projectile.delivery.projectile.fuse
			if fuse ~= nil and projectile.flight.age >= fuse then
				detonate(projectile, at, nil, false)
				finished = true
				break
			end
			if projectile.flight.age > projectile_mod.max_age(projectile.delivery) then
				detonate(projectile, at, nil, false)
				finished = true
				break
			end
			-- a shell that splits does so once it starts to come down
			local split = projectile.weapon.split
			if split ~= nil and projectile.flight.velocity.Y < 0 then
				for _, shot in split_shell(projectile, split, (steps - step) * sub_delta) do
					table.insert(split_shots, shot)
				end
				finished = true
				break
			end
		end

		if finished then
			remove(index)
		else
			index += 1
		end
	end
	for _, shot in split_shots do
		table.insert(projectiles, shot)
	end
end

-- Every rocket in flight, for interceptors to look for nukes in and for a test to watch (see server/tests). Nothing
-- may change the list.
local function in_flight(): { Projectile }
	return projectiles
end

-- Drops everything in flight, without any of it landing, as the map is replaced under it.
local function clear()
	for _, projectile in projectiles do
		projectile.flying = false
	end
	table.clear(projectiles)
	table.clear(nuke_list)
end

snapshot.keep("projectiles", function()
	return { projectiles = projectiles, nuke_list = nuke_list, next_projectile_id = next_projectile_id }
end, function(saved)
	projectiles = saved.projectiles
	nuke_list = saved.nuke_list
	next_projectile_id = saved.next_projectile_id
end)

return table.freeze({
	substeps = substeps,
	launch_point = launch_point,
	or_facing = or_facing,
	release_shot = release_shot,
	launch = launch,
	tick = tick,
	in_flight = in_flight,
	in_the_air = in_the_air,
	nukes = nukes,
	is_free_nuke = is_free_nuke,
	claim_nuke = claim_nuke,
	free_nuke = free_nuke,
	catch_nuke = catch_nuke,
	clear = clear,
	burst_harmlessly = burst_harmlessly,
})
