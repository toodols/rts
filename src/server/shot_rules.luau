--!strict
-- Whether a weapon can be fired at something, or at a bare point on the ground (`sight.Aim`): what it may be turned on
-- at all (`can_aim`), whether it reaches it (`reaches`), and whether it has a shot at it from where it fires
-- (`has_shot`). Nothing fires blind: the ground in the way stops a shot for good, and so does something on the
-- shooter's own side, since a shot is never taken through a friend on purpose. What the shot does once it has left is
-- the projectile's or the beam's business. `reach_against` asks it of every weapon something has.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile = require(ReplicatedStorage.Shared.projectile)

local state = require(script.Parent.state)
local sight = require(script.Parent.sight)

local is_lobbed = unit_defs.is_lobbed
local is_torpedo = unit_defs.is_torpedo
local layer_of = unit_defs.layer_of
local reaches_layer = unit_defs.reaches_layer

type Entity = types.Entity
type EntityId = types.EntityId
type Weapon = types.Weapon
type Aim = sight.Aim

-- A bomber searches for targets as far ahead as a bomb would carry falling to ground this much lower than what it
-- is over.
local DROP_SEARCH_DEPTH = 20
-- How far apart the points along a torpedo's way are checked for water deep enough to carry it.
local TORPEDO_PATH_SPACING = 4
-- How far apart along the ground the points of an arc are checked against the terrain.
local ARC_CHECK_SPACING = 4
-- How far past its flat range a target search for a lobbed shell looks: from above its target a shell reaches further
-- (`reach_at`), and these cover the most any map's heights let it, with `reach_at` having the exact say.
local LOBBED_SEARCH_SCALE = 1.25
local LOBBED_SEARCH_MARGIN = 100
-- The arcs a shell on the automatic arc tries, lowest first, before it takes the high one (`chosen_arc`).
local AUTO_ARCS: { types.Arc } = { "low", "medium" }

-- Whether the shell goes over whatever is in its way, and so needs no line of sight. Only the high, medium and
-- automatic arcs do (the last takes the high arc when the low one is in the way): a low one flies nearly straight, and
-- is stopped by a friend or the ground in its way like a laser. A missile leaves straight up, so nothing in front of it
-- matters either, and nor does it for a bomb, which falls from above everything.
local function flies_over(weapon: Weapon): boolean
	local delivery = weapon.delivery
	if delivery.kind == "lobbed" then
		return delivery.arc ~= "low"
	end
	return delivery.kind == "missile" or delivery.kind == "bomb"
end

-- Whether `weapon` can be fired from `origin` at all: nothing but a torpedo is fired from under the water, save a weapon
-- made to launch from there (`Weapon.launches_underwater`), a submarine's missile.
local function fires_from(weapon: Weapon, origin: Vector3): boolean
	return origin.Y >= ground_levels.WATER_LEVEL or is_torpedo(weapon) or weapon.launches_underwater == true
end

-- Whether a torpedo launched from `origin` has water all the way to `to`. It runs under the surface, so land
-- between the two stops it however clear the air over it is, and nothing else does: it goes under friends and
-- past them. The two ends are left out, since a launcher or its target can sit where the water is shallow.
local function through_water(origin: Vector3, to: Vector3): boolean
	local steps = math.floor(geometry.distance_2d(origin, to) / TORPEDO_PATH_SPACING)
	for index = 1, steps - 1 do
		local point = origin:Lerp(to, index / steps)
		if projectile.torpedo_runs_at(point.X, point.Z) == false then
			return false
		end
	end
	return true
end

-- How near the target the first bomb of a burst has to be going to come down for `attacker` to start it: half the
-- length of the line of bombs the burst lays along its path, as in BAR, so that the target is in the middle of the
-- line, the first bombs coming down short of it and the last ones past it. A weapon with no burst takes it as the
-- ground covered in one gap between shots.
local function drop_window(attacker: Entity, weapon: Weapon): number
	local gaps = math.max(1, (weapon.burst_count or 1) - 1)
	local interval = unit_defs.burst_interval(weapon)
	return gaps * interval * geometry.flatten(attacker.velocity).Magnitude / 2
end

-- The path a shot of `weapon` from `origin` to `to` really flies over the ground, where that is not the straight line
-- to it: a shell on the low arc flies above the line, and a lofted missile (StraightDelivery.loft) goes up and over.
-- Nil for any other shot.
local function arced_path(weapon: Weapon, origin: Vector3, to: Vector3): { Vector3 }?
	local delivery = weapon.delivery
	if delivery.kind == "lobbed" and delivery.arc == "low" then
		return projectile.trajectory(origin, to, delivery.projectile, "low", ARC_CHECK_SPACING)
	end
	if delivery.kind == "straight" and delivery.loft ~= nil then
		return projectile.loft_path(origin, to, delivery.loft, ARC_CHECK_SPACING)
	end
	return nil
end

-- Whether `attacker` has a shot at `aim` with `weapon` from `origin`: it has to be fired from there at all
-- (`fires_from`), and then a torpedo needs water all the way there, a shell that flies over what is in the way needs
-- nothing, and anything else needs a clear line, along the path it really flies (`arced_path`). Says what is in the way
-- as sight.verdict does: "clear" for a shot, "friendly" when only a friend is.
local function shot_verdict(attacker: Entity, weapon: Weapon, aim: Aim, origin: Vector3): sight.Verdict
	if fires_from(weapon, origin) == false then
		return "terrain"
	end
	local to = sight.position_of(aim)
	if is_torpedo(weapon) then
		return if through_water(origin, to) then "clear" else "terrain"
	end
	if flies_over(weapon) then
		return "clear"
	end
	return sight.verdict(attacker, aim, origin, arced_path(weapon, origin, to))
end

local function has_shot(attacker: Entity, weapon: Weapon, aim: Aim, origin: Vector3): boolean
	return shot_verdict(attacker, weapon, aim, origin) == "clear"
end

-- The arc a lobbed shot of `weapon` is fired along this time: its own, or for one on the automatic arc the lowest that
-- has a clear path: the low one, which is the faster, flatter and more accurate way, then the medium one, and the high
-- one when the ground or a friend is in the way of both. Nil for a weapon that lobs nothing.
local function chosen_arc(attacker: Entity, weapon: Weapon, origin: Vector3, aim: Aim): types.Arc?
	local delivery = weapon.delivery
	if delivery.kind ~= "lobbed" then
		return nil
	end
	if delivery.arc ~= "auto" then
		return delivery.arc
	end
	local to = sight.position_of(aim)
	for _, arc: types.Arc in AUTO_ARCS do
		local path = projectile.trajectory(origin, to, delivery.projectile, arc, ARC_CHECK_SPACING)
		if sight.verdict(attacker, aim, origin, path) == "clear" then
			return arc
		end
	end
	return "high"
end

-- How far `weapon` reaches from `origin` at something at `target_position`. What arcs reaches further from above its
-- target and less far from below it.
local function reach_at(weapon: Weapon, origin: Vector3, target_position: Vector3): number
	return projectile.range_to(weapon.range, origin, target_position, weapon.delivery)
end

-- How far along the ground from `position` a bomb let go from `origin` now would come down. It goes on at
-- `attacker`'s velocity as it falls, so it comes down some way ahead of where it was let go, and something moving
-- at `velocity` will have moved on by the time it lands.
local function drop_miss(
	attacker: Entity,
	params: types.ProjectileParams,
	origin: Vector3,
	position: Vector3,
	velocity: Vector3
): number
	local lands = projectile.fall_time(origin, attacker.velocity, params.gravity, position.Y)
	return geometry.distance_2d(origin + attacker.velocity * lands, position + velocity * lands)
end

-- Whether `position` is inside the cone of `attacker`'s that a weapon with a `fire_arc` fires into: ahead of it, or
-- turned `direction` radians off that (`Weapon.fire_direction`).
local function within_arc(attacker: Entity, arc: number, direction: number, position: Vector3): boolean
	local dx, dz = position.X - attacker.position.X, position.Z - attacker.position.Z
	if dx * dx + dz * dz < 1e-6 then
		return true
	end
	local off = geometry.wrap_angle(math.atan2(dx, dz) - attacker.facing - direction)
	return math.abs(off) <= arc
end

-- Whether `weapon`, fired by `attacker` from `origin`, reaches something at `position` moving at `velocity`, which
-- is `distance` from `attacker` along the ground. A bomb reaches only what it would come down within the drop
-- window of, and a weapon with a `fire_arc` nothing outside it.
local function reaches(
	attacker: Entity,
	weapon: Weapon,
	origin: Vector3,
	position: Vector3,
	velocity: Vector3,
	distance: number
): boolean
	if
		weapon.fire_arc ~= nil
		and within_arc(attacker, weapon.fire_arc, weapon.fire_direction or 0, position) == false
	then
		return false
	end
	local delivery = weapon.delivery
	if delivery.kind == "bomb" then
		return drop_miss(attacker, delivery.projectile, origin, position, velocity) < drop_window(attacker, weapon)
	end
	return distance <= reach_at(weapon, origin, position)
end

-- How far out a target search for `weapon` has to look. reach_at varies per candidate only for an
-- arced weapon (it reaches further from above its target than below it), so only that needs searching
-- a little wider than its flat range, with reach_at still getting the exact, final say per candidate;
-- anything else reaches exactly its range, and every stud past that is entities visited for nothing. A bomb
-- reaches its drop window around where it comes down, which is ahead of the bomber by as far as it carries.
local function search_radius(attacker: Entity, weapon: Weapon, origin: Vector3): number
	local delivery = weapon.delivery
	if delivery.kind == "lobbed" then
		return weapon.range * LOBBED_SEARCH_SCALE + LOBBED_SEARCH_MARGIN
	end
	if delivery.kind == "bomb" then
		local floor = heightmap.height_at(origin.X, origin.Z) - DROP_SEARCH_DEPTH
		local lands = projectile.fall_time(origin, attacker.velocity, delivery.projectile.gravity, floor)
		return drop_window(attacker, weapon) + geometry.flatten(attacker.velocity).Magnitude * lands
	end
	return weapon.range
end

-- Whether `weapon` can be turned on `target` at all. A torpedo is aimed at what is in the water and nothing else, and
-- is the only thing that is aimed at what is wholly under it. A weapon that names a layer shoots only at that one,
-- and a lobbed shell comes down where its target was, so it is never thrown at something in the air. An EMP weapon is
-- not turned on what EMP cannot stun, as BAR's are not (luarules/gadgets/unit_onlytargetempable.lua). Something
-- hanging from a transport can be shot at by any weapon that fires straight, whichever layer it names, since it is
-- up in the air and is still what it was on the ground.
local function can_target(weapon: Weapon, target: Entity): boolean
	local def = target.def
	if weapon.paralyze_time ~= nil and (def.emp_resistance or 0) >= 1 then
		return false
	end
	if state.carrier_of(target.id) ~= nil then
		return is_torpedo(weapon) == false and is_lobbed(weapon) == false
	end
	return reaches_layer(weapon, layer_of(def, target.position))
end

-- Whether `weapon` can be fired at a bare point on the ground at all: anything but a weapon that only shoots at
-- aircraft.
local function fires_at_points(weapon: Weapon): boolean
	return weapon.target_layer ~= "air"
end

-- Whether `weapon` can be turned on `aim` at all: something it can target (`can_target`), or a bare point it can be
-- fired at, which for a torpedo has to be in water it can run in.
local function can_aim(weapon: Weapon, aim: Aim): boolean
	if typeof(aim) ~= "Vector3" then
		return can_target(weapon, aim)
	end
	if is_torpedo(weapon) then
		return projectile.torpedo_runs_at(aim.X, aim.Z)
	end
	return fires_at_points(weapon)
end

-- How far the longest of `def`'s weapons that can be turned on `aim` reaches, counting only those an attack order
-- fires if it is a launch or not (`launch`, `unit_defs.fired_by_order`), and every one without it; nil if none can.
local function reach_against(def: types.EntityDef, aim: Aim, launch: boolean?): number?
	return unit_defs.longest_range(def, function(weapon: Weapon): boolean
		return (launch == nil or unit_defs.fired_by_order(weapon, launch)) and can_aim(weapon, aim)
	end)
end

return table.freeze({
	can_target = can_target,
	fires_at_points = fires_at_points,
	can_aim = can_aim,
	reach_against = reach_against,
	reaches = reaches,
	search_radius = search_radius,
	shot_verdict = shot_verdict,
	has_shot = has_shot,
	chosen_arc = chosen_arc,
})
