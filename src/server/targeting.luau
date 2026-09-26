--!strict
-- What each weapon shoots at. Acquisition is automatic: an armed unit with no attack order shoots the enemy in its
-- range that it would gain most from shooting and has a clear shot at (`pick_target`). An explicit attack order
-- overrides that choice for as long as what it names can be shot, a target or a point on the ground
-- (server/attack_orders.luau). A piloted unit's weapon shoots where its pilot aims (`pilot_choice`), and an anti-nuke's
-- at the enemy nuke it should go after. Whether a shot can be taken at all is shot_rules'.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local teams = require(ReplicatedStorage.Shared.teams)

local state = require(script.Parent.state)
local spatial = require(script.Parent.spatial)
local alliances = require(script.Parent.alliances)
local pilots = require(script.Parent.pilots)
local sight = require(script.Parent.sight)
local shot_rules = require(script.Parent.shot_rules)
local muzzles = require(script.Parent.muzzles)
local attack_orders = require(script.Parent.attack_orders)
local projectiles = require(script.Parent.projectiles)
local interceptors = require(script.Parent.interceptors)

type Entity = types.Entity
type EntityId = types.EntityId
type Weapon = types.Weapon
type Aim = sight.Aim

-- What a weapon would shoot at now: what it aims at, nothing if nil, and for an anti-nuke the nuke in flight its aim is
-- on, where that is now.
export type Choice = {
	aim: Aim?,
	nuke: projectiles.Projectile?,
}

-- How many candidate targets are checked for line of sight, nearest first, before giving up.
local MAX_SIGHT_CHECKS = 6
-- A piloted shot aimed at a point is fired this far on past it, so that the line it is fired along goes into whatever
-- the point is on the face of, and strikes it, rather than stopping just short.
local PILOT_AIM_PAST = 1
-- How far off the line a pilot aims along, in radians, an aircraft may be for an anti air weapon to lock on to it.
local PILOT_LOCK_CONE = math.rad(12)
-- How near an enemy has to be to something stealthy (`EntityDef.stealth`) for its weapons to pick it as a target,
-- in studs: about BAR's line of sight for a light unit, which is all it has to spot something its radar does not show.
local STEALTH_DETECTION_RANGE = 32

local NOTHING: Choice = table.freeze({ aim = nil, nuke = nil })

-- What `pick_target` found for a weapon this tick with nothing claimed: the best target it has a clear shot at, or nil
-- for none.
type Pick = { target: Entity? }

-- Each weapon's pick for the tick, by attacker and weapon, so that nothing asks the same question twice in one tick: a
-- fight order's "is there anything to shoot" (`any_target`) and the shot the unit then takes. It is only ever what was
-- true when it was made, so a target that has died since is picked afresh. `any_target` notes that there is none when it
-- finds nothing at all in reach, which spares the shot the same fruitless scan. Cleared at the top of the tick
-- (`begin_tick`), before orders, so it holds for the whole of it.
local picks: { [EntityId]: { [Weapon]: Pick } } = {}

-- Whether `other` is an enemy of `attacker`'s: alive, of a side that is not its own or an ally's, and not neutral, as
-- remains and scenery are, which are nobody's to fight.
local function is_enemy(attacker: Entity, other: Entity): boolean
	return other.alive and other.team ~= teams.NEUTRAL and alliances.are_allied(attacker.team, other.team) == false
end

-- Whether `other` can be shot given an explicit attack order: an enemy, or a wreck, so that a weapon (a beam laser
-- included) can be ordered to finish one off.
local function is_valid_forced_target(attacker: Entity, other: Entity): boolean
	return is_enemy(attacker, other) or (other.alive and other.def.kind == "wreck")
end

-- Whether a weapon picking for itself makes out `other`, `distance` studs off: anything, save that something stealthy
-- is only made out from close by (`EntityDef.stealth`). An order to attack it is not a pick, and needs no spotting.
local function spots(other: Entity, distance: number): boolean
	return distance <= STEALTH_DETECTION_RANGE or other.def.stealth ~= true
end

-- Whether `weapon` of `attacker`'s, fired from `origin`, could be fired at `other`, `distance` studs off along the
-- ground, as far as its own rules go: an enemy it can be turned on and reaches. Whether it has a clear shot is another
-- matter (`shot_rules.has_shot`), and so is whether it would make it out if it were picking for itself (`spots`).
local function eligible(attacker: Entity, weapon: Weapon, origin: Vector3, other: Entity, distance: number): boolean
	return is_enemy(attacker, other)
		and shot_rules.can_target(weapon, other)
		and shot_rules.reaches(attacker, weapon, origin, other.position, other.velocity, distance)
end

-- What shooting something of `def` with `health` left is worth to a weapon (made for shooting aircraft if `anti_air`):
-- its power (`unit_defs.power`) over its health, so what is closest to dying comes first, times the share of the
-- weapon's damage it would actually take. What pick_target ranks by, and the AI's fight predictor
-- (server/ai/combat_sim.luau) too.
local function reward(anti_air: boolean, def: types.EntityDef, health: number): number
	return unit_defs.power(def) * unit_defs.damage_against(anti_air, def, 1) / math.max(health, 1e-3)
end

-- What `attacker` shoots at when it fires from `origin`: the highest reward enemy in range it has a clear
-- shot at, skipping any target already `claimed`, scored as below. With none it holds fire: a shot
-- that a friend is standing in is never taken on purpose.
local function pick_target(attacker: Entity, origin: Vector3, weapon: Weapon, claimed: { EntityId }): Entity?
	if spatial.any_enemy_of(attacker.team) == false then
		return nil
	end
	local candidates: { Entity } = {}
	local distances: { [Entity]: number } = {}
	local search_radius = shot_rules.search_radius(attacker, weapon, origin)
	local own_root = alliances.root_of(attacker.team)
	spatial.each_target(attacker.position.X, attacker.position.Z, search_radius, own_root, function(other: Entity)
		-- distance first: out of reach is by far the most common reason to reject, and the cheapest
		local distance = geometry.distance_2d(attacker.position, other.position)
		if distance > search_radius then
			return nil
		end
		if
			eligible(attacker, weapon, origin, other, distance)
			and spots(other, distance)
			and table.find(claimed, other.id) == nil
		then
			table.insert(candidates, other)
			distances[other] = distance
		end
		return nil
	end)
	-- Ranked by `reward`: an aircraft that takes 15% from a weapon that is not anti air is worth 15% of what it would be
	-- to one that is.
	local rewards: { [Entity]: number } = {}
	local anti_air = unit_defs.is_anti_air(weapon)
	for _, other in candidates do
		rewards[other] = reward(anti_air, other.def, other.health)
	end
	-- the highest reward first, and the nearest of those that are worth the same
	table.sort(candidates, function(a: Entity, b: Entity): boolean
		local reward_a = rewards[a]
		local reward_b = rewards[b]
		if reward_a ~= reward_b then
			return reward_a > reward_b
		end
		return distances[a] < distances[b]
	end)

	for index, other in candidates do
		if index > MAX_SIGHT_CHECKS then
			break
		end
		if shot_rules.has_shot(attacker, weapon, other, origin) then
			return other
		end
	end
	return nil
end

-- The pick for `weapon` of `attacker`'s already made this tick, if there is one (`picks`).
local function known_pick(attacker: Entity, weapon: Weapon): Pick?
	local by_weapon = picks[attacker.id]
	return if by_weapon ~= nil then by_weapon[weapon] else nil
end

local function remember_pick(attacker: Entity, weapon: Weapon, target: Entity?)
	local by_weapon = picks[attacker.id]
	if by_weapon == nil then
		by_weapon = {}
		picks[attacker.id] = by_weapon
	end
	by_weapon[weapon] = { target = target }
end

-- `pick_target`, from this tick's pick where that answers it. A target picked with nothing claimed is still the pick
-- with some claimed if it is not one of them itself and is still alive, since whatever was ranked above it had no clear
-- shot, claimed or not. Anything else is picked afresh, and with nothing claimed remembered.
local function remembered_pick(attacker: Entity, origin: Vector3, weapon: Weapon, claimed: { EntityId }): Entity?
	local known = known_pick(attacker, weapon)
	if known ~= nil then
		local target = known.target
		if target == nil then
			if #claimed == 0 then
				return nil
			end
		elseif target.alive and table.find(claimed, target.id) == nil then
			return target
		end
	end
	local target = pick_target(attacker, origin, weapon, claimed)
	if #claimed == 0 then
		remember_pick(attacker, weapon, target)
	end
	return target
end

-- Whether `weapon` has anything at all it could fire on from `origin` right now - not which target is
-- best, which is what pick_target is for. A fight order asks this every tick just to decide whether to
-- stand or keep walking, while the unit only actually picks and fires once per reload, so paying for a
-- full scan-and-sort here was most of the cost of a battle. This stops at the first enemy in reach it
-- has a shot at, and, like pick_target, gives up once MAX_SIGHT_CHECKS of them turn out to be blocked.
-- Answers from this tick's pick if one has been made. With `past_friends`, an enemy that only a friend stands in the
-- way of counts too, and a pick's having found nothing, which counts only clear shots, settles nothing.
local function any_target(attacker: Entity, origin: Vector3, weapon: Weapon, past_friends: boolean): boolean
	local known = known_pick(attacker, weapon)
	if known ~= nil then
		local target = known.target
		if target == nil and past_friends == false then
			return false
		elseif target ~= nil and target.alive then
			return true
		end
	end
	if spatial.any_enemy_of(attacker.team) == false then
		return false
	end
	local search_radius = shot_rules.search_radius(attacker, weapon, origin)
	local own_root = alliances.root_of(attacker.team)
	local found = false
	local blocked = 0
	spatial.each_target(
		attacker.position.X,
		attacker.position.Z,
		search_radius,
		own_root,
		function(other: Entity): boolean?
			-- distance first: out of reach is by far the most common reason to reject, and the cheapest
			local distance = geometry.distance_2d(attacker.position, other.position)
			if
				distance > search_radius
				or eligible(attacker, weapon, origin, other, distance) == false
				or spots(other, distance) == false
			then
				return nil
			end
			local verdict = shot_rules.shot_verdict(attacker, weapon, other, origin)
			if verdict == "clear" or (past_friends and verdict == "friendly") then
				found = true
				return true
			end
			blocked += 1
			return blocked >= MAX_SIGHT_CHECKS
		end
	)
	-- Nothing in reach at all means pick_target has no candidates either, so its answer is already
	-- known - and a shooter with nothing to shoot never starts a reload, so without this its own
	-- shot would pay for the same fruitless scan again this very tick.
	if found == false and blocked == 0 then
		remember_pick(attacker, weapon, nil)
	end
	return found
end

-- Whether `weapon` could be fired at `aim` by what an attack order it carries out names: a point it can be fired at, or
-- a target that is there to be shot and that it can be turned on.
local function orderable(attacker: Entity, weapon: Weapon, aim: Aim): boolean
	local target = sight.target_of(aim)
	return (target == nil or is_valid_forced_target(attacker, target)) and shot_rules.can_aim(weapon, aim)
end

-- What an attack order that `weapon` carries out names for `attacker`, if it can be shot with it right now: it is
-- reached, and, as a pick would be, it can be seen.
local function forced(attacker: Entity, weapon: Weapon, origin: Vector3): Aim?
	local aim = attack_orders.aim_of(attacker)
	if
		aim == nil
		or attack_orders.answered_by(attacker, weapon) == false
		or orderable(attacker, weapon, aim) == false
	then
		return nil
	end
	local position = sight.position_of(aim)
	local distance = geometry.distance_2d(attacker.position, position)
	if
		shot_rules.reaches(attacker, weapon, origin, position, sight.velocity_of(aim), distance)
		and shot_rules.has_shot(attacker, weapon, aim, origin)
	then
		return aim
	end
	return nil
end

-- Whether `attacker` has an attack order `weapon` could carry out, reachable or not.
local function has_order_for(attacker: Entity, weapon: Weapon): boolean
	local aim = attack_orders.aim_of(attacker)
	return aim ~= nil and attack_orders.answered_by(attacker, weapon) and orderable(attacker, weapon, aim)
end

-- What `weapon` would shoot at now, if anything: what an attack order names if it can be shot now, and otherwise the
-- best enemy that can be seen, preferring one that is not `claimed`. An anti-nuke weapon looks instead for an enemy
-- nuke coming down within its range that no interceptor is after yet (`interceptors.pick_nuke`), and aims where it is.
local function choose(attacker: Entity, weapon: Weapon, origin: Vector3, claimed: { EntityId }): Choice
	if unit_defs.is_anti_nuke(weapon) then
		local nuke = interceptors.pick_nuke(origin, attacker.team, weapon.range)
		return if nuke ~= nil then { aim = nuke.flight.position, nuke = nuke } else NOTHING
	end
	local ordered = forced(attacker, weapon, origin)
	if ordered ~= nil then
		return { aim = ordered, nuke = nil }
	end
	-- a manual-fire weapon shoots at what a launch tells it to and nothing else
	if weapon.manual_fire == true then
		return NOTHING
	end
	-- nor does a bomb on its way to what it was ordered to attack, as in BAR: a burst let go on the way would leave it
	-- reloading when it gets there
	if weapon.delivery.kind == "bomb" and has_order_for(attacker, weapon) then
		return NOTHING
	end
	local target = remembered_pick(attacker, origin, weapon, claimed)
	-- take a target another weapon is already shooting over none
	if target == nil and #claimed > 0 then
		target = remembered_pick(attacker, origin, weapon, {})
	end
	return { aim = target, nuke = nil }
end

-- What the chosen weapon of a piloted unit shoots at (see shared/piloting.luau): the very point its pilot aims at, or as
-- far as it reaches toward it, and whatever is on the line there is what it hits, whether or not it was aimed at. Only
-- a weapon that cannot be fired at a point, one that shoots at nothing but aircraft, is fired at the enemy aimed at, if
-- it can reach it. It is fired whether or not that can be seen, as a pilot fires where they like.
local function pilot_choice(attacker: Entity, weapon: Weapon, origin: Vector3, pilot: pilots.Pilot): Choice
	if shot_rules.fires_at_points(weapon) == false then
		local function usable(other: Entity): boolean
			return eligible(attacker, weapon, origin, other, geometry.distance_2d(attacker.position, other.position))
		end
		local target_id = pilot.target_id
		local target = if target_id ~= nil then state.get(target_id, true) else nil
		if target ~= nil and usable(target) then
			return { aim = target, nuke = nil }
		end
		-- an aircraft is too quick to keep the crosshair on, so it locks on to whichever it can shoot is nearest the
		-- line aimed along, if one is within PILOT_LOCK_CONE of it
		local aim = pilot.aim
		local line = if aim ~= nil then aim - origin else Vector3.zero
		if aim == nil or line.Magnitude < 1e-3 then
			return NOTHING
		end
		local direction = line.Unit
		-- with nothing to lock on to it is fired where it is aimed all the same, as far as it reaches, unguided
		local within = aim
		local across = geometry.flatten(line).Magnitude
		if across > weapon.range then
			within = origin + line * (weapon.range / across)
		end
		local best: Entity? = nil
		local best_angle = PILOT_LOCK_CONE
		spatial.each_target(
			attacker.position.X,
			attacker.position.Z,
			weapon.range,
			alliances.root_of(attacker.team),
			function(other: Entity): boolean?
				local to = other.position - origin
				if to.Magnitude < 1e-3 then
					return nil
				end
				local angle = math.acos(math.clamp(to.Unit:Dot(direction), -1, 1))
				if angle < best_angle and usable(other) then
					best = other
					best_angle = angle
				end
				return nil
			end
		)
		if best ~= nil then
			return { aim = best, nuke = nil }
		end
		return { aim = within, nuke = nil }
	end
	local aim = pilot.aim
	if aim == nil then
		return NOTHING
	end
	local line = aim - origin
	if line.Magnitude > 1e-3 and unit_defs.is_lobbed(weapon) == false then
		aim += line.Unit * PILOT_AIM_PAST
	end
	-- aimed further than it reaches, it fires as far as it reaches along the line aimed down, into the air if that is
	-- where the line goes; a lobbed shell, which comes down where it is aimed, comes down on the ground there instead
	local across = geometry.flatten(aim - origin).Magnitude
	if across > weapon.range then
		local within = origin + (aim - origin) * (weapon.range / across)
		aim = if unit_defs.is_lobbed(weapon) then heightmap.ground_position(within.X, within.Z) else within
	end
	return { aim = aim, nuke = nil }
end

-- Whether `entity` has something it could shoot at this moment: an enemy within range of any of its
-- weapons that it has a clear line to, whether or not the weapon is reloading. With `past_friends`, one that only a
-- friend is in the line to counts as well: that is what makes a unit on a fight order stop walking, so that one behind
-- a friend holds where it is, and fires once the line clears, rather than walking on and shoving the friends in front
-- of it into the enemy's reach.
local function has_target(entity: Entity, past_friends: boolean?): boolean
	local weapons = entity.def.weapons
	if weapons == nil then
		return false
	end
	local frame = muzzles.frame_of(entity)
	for index, weapon in weapons do
		if any_target(entity, muzzles.origin_of(entity, frame, index), weapon, past_friends == true) then
			return true
		end
	end
	return false
end

-- Whether any of `entity`'s weapons could hit `aim`, something or a point on the ground, from where it stands now: it
-- can be turned on it, reaches it, and has a clear shot at it, whether or not it is reloading. It is what an attack
-- order walks on until it has, since being in range of something behind a hill is not being able to shoot it.
local function can_shoot(entity: Entity, aim: Aim): boolean
	local weapons = entity.def.weapons
	if weapons == nil then
		return false
	end
	local frame = muzzles.frame_of(entity)
	local position = sight.position_of(aim)
	local velocity = sight.velocity_of(aim)
	local distance = geometry.distance_2d(entity.position, position)
	for index, weapon in weapons do
		if shot_rules.can_aim(weapon, aim) == false then
			continue
		end
		local origin = muzzles.origin_of(entity, frame, index)
		if
			shot_rules.reaches(entity, weapon, origin, position, velocity, distance)
			and shot_rules.has_shot(entity, weapon, aim, origin)
		then
			return true
		end
	end
	return false
end

-- Clears the tick's picks for the tick about to run, before orders do anything, so a fight order's has_target check
-- and this same tick's actual shot share one pick per (attacker, weapon), as they share the targets `spatial` holds for
-- the tick.
local function begin_tick()
	table.clear(picks)
end

return table.freeze({
	STEALTH_DETECTION_RANGE = STEALTH_DETECTION_RANGE,
	begin_tick = begin_tick,
	is_enemy = is_enemy,
	is_valid_forced_target = is_valid_forced_target,
	spots = spots,
	reward = reward,
	eligible = eligible,
	choose = choose,
	pilot_choice = pilot_choice,
	has_target = has_target,
	can_shoot = can_shoot,
})
