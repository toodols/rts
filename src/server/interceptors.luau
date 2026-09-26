--!strict
-- Anti-nuke interceptors in flight. An anti-nuke (`weapon_kinds`' `anti_nuke`) fires at nothing but an enemy nuclear
-- missile coming down within its coverage, its weapon's range (`pick_nuke`, which targeting asks). Its interceptor flies
-- at where it will meet that nuke and homes onto it all the way; when it comes near enough it catches it, as in BAR one
-- is all it takes, and the nuke goes off there in the air, for show: the blast harms nothing, not even aircraft flying
-- through it. The interceptor strikes nothing else, and harms nothing wherever it ends. The nukes themselves fly with
-- every other projectile (server/projectiles.luau), which keeps what an interceptor needs of one.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile_mod = require(ReplicatedStorage.Shared.projectile)

local projectiles = require(script.Parent.projectiles)
local alliances = require(script.Parent.alliances)

type Entity = types.Entity
type Projectile = projectiles.Projectile

export type Interceptor = {
	id: number,
	flight: projectile_mod.Flight,
	-- how it flies, its weapon's
	delivery: types.ProjectileDelivery,
	-- the nuke it chases
	chased: Projectile,
}

-- How near an interceptor has to come to the nuke it chases to catch it: about the nuke's own length.
local INTERCEPT_RADIUS = 4

local interceptors: { Interceptor } = {}

-- The enemy nuke an anti-nuke of `team` at `position` launches at, if there is one: as in BAR, one that is coming down
-- within its `coverage` (its weapon's range), wherever the nuke is now, and that no interceptor is chasing yet. The one
-- that will land nearest it goes first. A nuke still climbing out of its silo is left alone until it levels off at its
-- cruising height, so the interceptor meets it up there rather than over the silo it was fired from.
local function pick_nuke(position: Vector3, team: types.TeamId, coverage: number): Projectile?
	local nearest: Projectile? = nil
	local nearest_distance = coverage
	for _, candidate in projectiles.nukes() do
		local nuke = candidate.nuke :: projectiles.Nuke
		if
			candidate.flight.phase ~= "climb"
			and projectiles.is_free_nuke(candidate)
			and alliances.are_allied(candidate.team, team) == false
		then
			local distance = Vector2.new(nuke.aim.X - position.X, nuke.aim.Z - position.Z).Magnitude
			if distance <= nearest_distance then
				nearest = candidate
				nearest_distance = distance
			end
		end
	end
	return nearest
end

-- Launches an interceptor, a shot of weapon `index` of `owner`'s, `weapon`, from `origin` after `chased`, a nuke nothing
-- is after yet (`pick_nuke`), aimed where it will meet it. It was fired `late` seconds ago, partway through the tick, as
-- `projectiles.launch` has it.
local function launch(
	owner: Entity,
	weapon: types.Weapon,
	index: number,
	origin: Vector3,
	chased: Projectile,
	late: number
)
	local delivery = weapon.delivery
	assert(delivery.kind == "straight", "an interceptor flies straight at the nuke it chases")
	local params = delivery.projectile
	origin = projectiles.launch_point(owner, origin, late)
	local at = chased.flight.position
	local aim = at + chased.flight.velocity * projectile_mod.time_to_reach((at - origin).Magnitude, params)
	local direction = projectiles.or_facing(aim - origin, owner)
	-- the client steers the one it draws onto the nuke it chases
	local id, flight = projectiles.release_shot(
		owner,
		weapon,
		index,
		origin,
		{ direction = direction, shot = { speed = params.speed }, inherited = nil },
		aim,
		late,
		nil,
		chased.id
	)
	projectiles.claim_nuke(chased, id)
	table.insert(interceptors, { id = id, flight = flight, delivery = delivery, chased = chased })
end

-- Flies `interceptor` on for `delta` seconds after the nuke it chases, and says whether it has ended: caught the nuke,
-- or come down, gone off the map or flown too long without, which leaves the nuke free for another to go after.
local function fly(interceptor: Interceptor, delta: number): boolean
	local chased = interceptor.chased
	local flight = interceptor.flight
	local radius = interceptor.delivery.projectile.aoe_radius
	local steps, sub_delta = projectiles.substeps(flight, delta)
	for _ = 1, steps do
		projectile_mod.home(
			flight,
			interceptor.delivery.projectile,
			chased.flight.position,
			chased.flight.velocity,
			sub_delta
		)
		projectile_mod.step(flight, interceptor.delivery, sub_delta)
		local at = flight.position
		if (chased.flight.position - at).Magnitude <= INTERCEPT_RADIUS then
			projectiles.catch_nuke(chased)
			projectiles.burst_harmlessly(interceptor.id, at, radius, "burst")
			return true
		end
		local floor = math.max(heightmap.height_at(at.X, at.Z), ground_levels.WATER_LEVEL)
		if
			heightmap.in_bounds(at.X, at.Z) == false
			or at.Y <= floor
			or flight.age > projectile_mod.max_age(interceptor.delivery)
		then
			projectiles.free_nuke(chased)
			projectiles.burst_harmlessly(interceptor.id, at, radius, "burst")
			return true
		end
	end
	return false
end

-- Flies every interceptor forward one tick. One whose nuke has come down some other way has nothing left to do, and
-- goes off where it is.
local function tick(delta: number)
	local index = 1
	while index <= #interceptors do
		local interceptor = interceptors[index]
		local ended: boolean
		if projectiles.in_the_air(interceptor.chased) then
			ended = fly(interceptor, delta)
		else
			projectiles.burst_harmlessly(
				interceptor.id,
				interceptor.flight.position,
				interceptor.delivery.projectile.aoe_radius,
				"burst"
			)
			ended = true
		end
		if ended then
			table.remove(interceptors, index)
		else
			index += 1
		end
	end
end

-- Every interceptor in flight, for a test to watch (see server/tests). Nothing may change the list.
local function in_flight(): { Interceptor }
	return interceptors
end

-- Drops everything in flight, as the map is replaced under it.
local function clear()
	table.clear(interceptors)
end

return table.freeze({
	in_flight = in_flight,
	pick_nuke = pick_nuke,
	launch = launch,
	tick = tick,
	clear = clear,
})
