-- Weapons, damage and death.
--
-- Acquisition is automatic: an armed unit with no attack order shoots the nearest enemy inside its
-- range that it has a clear line of sight to. An explicit attack order overrides that choice for as
-- long as the target lives, stays in range and can be seen. An attack-ground order names a point instead
-- of a target and overrides it the same way, for as long as the point is in range and can be seen.
--
-- Nothing fires blind. The ground in the way stops a shot for good, and so does something on the
-- shooter's own side: a shot is never taken through a friend on purpose. Friendly fire is what happens
-- after a shot has left, when a friend walks into it. Hitscan weapons strike the first solid thing on
-- their line, and rockets fly there and hit what they meet.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile = require(ReplicatedStorage.Shared.projectile)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local sight = require(script.Parent.sight)
local alliances = require(script.Parent.alliances)
local docking = require(script.Parent.docking)
local projectiles = require(script.Parent.projectiles)
local air = require(script.Parent.air)
local deformation = require(script.Parent.deformation)
local movement = require(script.Parent.movement)
local profiler = require(script.Parent.profiler)

type Entity = types.Entity
type EntityId = types.EntityId

local weapon_fired: RemoteEvent = ReplicatedStorage.Shared.WeaponFired

-- Runs a line-of-sight check (any of sight.verdict/verdict_along/verdict_to_point/first_hit/
-- first_hit_at) under its own profiler label, `combat_los`, split out of the general `combat` one -
-- sight.luau does its own scan for blockers, so it is worth seeing apart from targeting, firing and
-- everything else combat.tick does. Whatever section was open - combat's own, or orders' when a
-- fight order asks has_target - is reopened the moment this returns, so nothing outside the call is
-- misattributed.
local function los(check: (...any) -> any, ...: any): any
	local previous = profiler.current()
	profiler.mark "combat_los"
	local result = check(...)
	profiler.mark(previous)
	return result
end

-- What a death leaves behind depends on how hard the unit was hit, as in BAR: its unit scripts read the
-- severity of the death, the damage taken lately as a percentage of the unit's health, and leave a whole wreck
-- up to 25 and nothing past that; this game has no heaps. Spring keeps the damage taken lately by adding each hit to
-- a running total that is multiplied by 0.9 every frame, at 30 frames a second, so it is the killing blow and
-- whatever landed with it. The blow counts in full, not only the part that was needed to kill.
local WRECK_MAX_SEVERITY = 25
local RECENT_DAMAGE_DECAY = 0.9
local FRAMES_PER_SECOND = 30

-- Damage taken lately, by entity, decayed a little every tick.
local recent_damage: { [EntityId]: number } = {}

-- How many candidate targets are checked for line of sight, nearest first, before giving up.
local MAX_SIGHT_CHECKS = 6

-- Target acquisition scans a flat (X, Z) grid instead of every living thing, the same idea as
-- movement's separation: rebuilt once a tick (see `rebuild_target_grid`), a search only visits the
-- cells within a weapon's own reach instead of the whole map. Most weapons reach nowhere near far
-- enough to make that expensive; the rare ones that do (a nuclear silo's whole-map range, say) just
-- fall back to the plain scan below, since at that range almost everything is a candidate cell
-- anyway and partitioning buys nothing.
local TARGET_CELL = 256
-- Past this many rings out from the shooter, the grid is visiting more empty cells than it is
-- saving real work, so pick_target falls back to a plain scan instead.
local TARGET_GRID_MAX_RINGS = 8

-- Each cell buckets its entities again by alliance root (alliances.root_of), not just by position: two
-- entities can only be enemies if their roots differ, so a search for `attacker`'s targets can skip
-- straight past its own root's bucket in every cell it visits, rather than visiting every nearby
-- friend and rejecting each one with is_enemy. In a crowd that is mostly or entirely one side - a solo
-- army with nobody around to fight, or just everyone's own front line - that is most of the cell.
type TargetCell = { [number]: { Entity } }
type TargetGrid = { [number]: { [number]: TargetCell } }

local target_grid: TargetGrid = {}

-- pick_target's result for (attacker, weapon), cached for the rest of the tick it was computed in -
-- orders.run_fight asks has_target purely to decide whether to keep walking or stand and fight, and
-- combat.tick asks the exact same question (same attacker, same weapon, same empty `claimed`) a
-- moment later to actually take the shot. Without this, every unit on a fight order pays for that
-- scan-and-sort twice a tick for no reason. Only valid when `claimed` is empty - the one case both
-- call sites share - so a turret already skipping a claimed target always computes fresh. Cleared in
-- begin_tick(), which also runs before orders.tick(), so it holds for the whole tick, not just
-- within a single call to tick().
local pick_target_cache: { [EntityId]: { [types.Weapon]: Entity | false } } = {}

-- Alliance roots seen on any living, non-wreck, non-neutral entity this tick, checked before a search
-- bothers walking the grid at all: with only one root anywhere on the map (a solo benchmark scenario,
-- or a lone player with nothing else spawned yet), nothing anywhere could possibly be an enemy.
local present_roots: { [number]: boolean } = {}
local present_root_count = 0

local function target_cell_of(x: number, z: number): (number, number)
	return math.floor(x / TARGET_CELL), math.floor(z / TARGET_CELL)
end

-- Rebuilt once at the top of every combat tick, from every living thing on the map - a target search
-- does not care what kind or team something is; `is_enemy` still does all of that filtering.
local function rebuild_target_grid()
	table.clear(target_grid)
	table.clear(present_roots)
	present_root_count = 0
	for _, entity in state.all() do
		if entity.alive == false then
			continue
		end
		local cx, cz = target_cell_of(entity.position.X, entity.position.Z)
		local column = target_grid[cx]
		if column == nil then
			column = {}
			target_grid[cx] = column
		end
		local cell = column[cz]
		if cell == nil then
			cell = {}
			column[cz] = cell
		end
		-- wrecks are bucketed under their own team's root, same as anything else - is_valid_forced_target
		-- lets a forced attack finish one off regardless of root, and that path does not go through
		-- each_within at all (it looks the wreck up by id directly), so nothing here needs to special-case it
		local root = alliances.root_of(entity.team)
		local bucket = cell[root]
		if bucket == nil then
			bucket = {}
			cell[root] = bucket
		end
		table.insert(bucket, entity)

		-- team 0 is neutral scenery, never a target (see is_enemy), so it never makes a shooter think
		-- an enemy might be out there
		if entity.kind ~= "wreck" and entity.team ~= 0 then
			if present_roots[root] == nil then
				present_roots[root] = true
				present_root_count += 1
			end
		end
	end
end

-- Whether anything on the map could possibly be an enemy of `attacker` right now: some living,
-- non-wreck entity whose alliance root differs from its own. Checked before a target search bothers
-- scanning the grid at all.
local function has_any_possible_enemy(attacker: Entity): boolean
	if present_root_count > 1 then
		return true
	end
	if present_root_count == 0 then
		return false
	end
	return present_roots[alliances.root_of(attacker.team)] == nil
end

-- Calls `visit` with every living entity that could possibly be within `radius` of (x, z) and is not
-- of `own_root`: everyone but that root, if `radius` is wide enough that the grid would not save
-- anything, or otherwise everyone but that root in the cells the search radius actually touches.
local function each_within(x: number, z: number, radius: number, own_root: number, visit: (Entity) -> ())
	local rings = math.ceil(radius / TARGET_CELL)
	if rings > TARGET_GRID_MAX_RINGS then
		for _, entity in state.all() do
			if entity.alive and alliances.root_of(entity.team) ~= own_root then
				visit(entity)
			end
		end
		return
	end
	local cx, cz = target_cell_of(x, z)
	for gx = cx - rings, cx + rings do
		local column = target_grid[gx]
		if column ~= nil then
			for gz = cz - rings, cz + rings do
				local cell = column[gz]
				if cell ~= nil then
					for root, bucket in cell do
						if root ~= own_root then
							for _, entity in bucket do
								visit(entity)
							end
						end
					end
				end
			end
		end
	end
end

-- The gap between shots within a burst, for a burst weapon that does not say its own (`burst_interval`).
-- Short enough to read as one rapid burst rather than a weapon that simply reloads fast.
local DEFAULT_BURST_INTERVAL = 0.1

-- Locked targets, kept outside Entity so the record stays flat.
local locked: { [EntityId]: EntityId } = {}
-- Points on the ground that shooters were ordered to attack; a shooter has one of these or a locked
-- target, never both.
local locked_ground: { [EntityId]: Vector3 } = {}

-- Progress value from the previous frame for each entity's stockpile, used to calculate incremental
-- resource drain.
local stockpile_progress_previous: { [EntityId]: number } = {}

-- Shooters that have launched a stockpiled missile since their orders last looked, which is what ends the attack
-- order that told them to.
local launched: { [EntityId]: boolean } = {}

-- When each shooter last had a target and could not pay for the shot, so that it can say so.
local STARVED_SHOWN_FOR = 0.4
local starved_at: { [EntityId]: number } = {}

local function is_enemy(attacker: Entity, other: Entity): boolean
	if other.alive == false then
		return false
	end
	if other.kind == "wreck" then
		return false
	end
	if alliances.are_allied(attacker.team, other.team) then
		return false
	end
	-- team 0 is neutral scenery, never a target
	return other.team ~= 0
end

-- Whether `other` can be shot given an explicit attack order: the same as `is_enemy`, but a wreck is
-- also a valid target, so a weapon (a beam laser included) can be ordered to finish one off.
local function is_valid_forced_target(attacker: Entity, other: Entity): boolean
	if other.alive == false then
		return false
	end
	if other.kind == "wreck" then
		return true
	end
	return is_enemy(attacker, other)
end

-- A shell of any arc comes down where its target was, so it is never thrown at something in the air. Neither
-- is a missile, which goes up and comes down on where its target was.
local function is_lobbed(weapon: types.Weapon): boolean
	return weapon.projectile ~= nil and (weapon.projectile.arc ~= nil or weapon.projectile.missile ~= nil)
end

-- Whether the shell goes over whatever is in its way, and so needs no line of sight. Only the high, medium and
-- automatic arcs do (the last takes the high arc when the low one is in the way): a low one flies nearly straight, and is stopped by a friend or the ground in its way like a laser. A
-- missile leaves straight up, so nothing in front of it matters either.
local function flies_over(weapon: types.Weapon): boolean
	return weapon.projectile ~= nil
		and (
			weapon.projectile.arc == "high"
			or weapon.projectile.arc == "medium"
			or weapon.projectile.arc == "auto"
			or weapon.projectile.missile ~= nil
		)
end

-- How far apart along the ground the points of an arc are checked against the terrain.
local ARC_CHECK_SPACING = 4

-- Whether `attacker`, firing `weapon` from `origin`, has a shot at `target`. A shell on the low arc flies above the
-- straight line to its target, so the ground is judged along the arc it really takes and not along that line.
local function verdict_at(attacker: Entity, weapon: types.Weapon, target: Entity, origin: Vector3): string
	local params = weapon.projectile
	if params ~= nil and params.arc == "low" then
		local path = projectile.trajectory(origin, target.position, params, ARC_CHECK_SPACING)
		return los(sight.verdict_along, attacker, target.position, origin, path, target.id)
	end
	return los(sight.verdict, attacker, target, origin)
end

-- The same for a bare point on the ground.
local function verdict_at_point(attacker: Entity, weapon: types.Weapon, point: Vector3, origin: Vector3): string
	local params = weapon.projectile
	if params ~= nil and params.arc == "low" then
		local path = projectile.trajectory(origin, point, params, ARC_CHECK_SPACING)
		return los(sight.verdict_along, attacker, point, origin, path, attacker.id)
	end
	return los(sight.verdict_to_point, attacker, point, origin)
end

-- A weapon on the automatic arc fires along the lowest arc that has a clear path: the low one, which is the faster,
-- flatter and more accurate way, then the medium one, and the high one when the ground or a friend is in the way of
-- both. Returns the weapon as it will fire this shot; any other weapon is returned as it is.
local function with_chosen_arc(
	attacker: Entity,
	weapon: types.Weapon,
	origin: Vector3,
	target_position: Vector3,
	ignored: EntityId
): types.Weapon
	local params = weapon.projectile
	if params == nil or params.arc ~= "auto" then
		return weapon
	end
	local chosen = table.clone(weapon)
	local shot = table.clone(params)
	shot.arc = "high"
	for _, arc in { "low", "medium" } do
		local trial = table.clone(params)
		trial.arc = arc :: "low" | "medium"
		local path = projectile.trajectory(origin, target_position, trial, ARC_CHECK_SPACING)
		if los(sight.verdict_along, attacker, target_position, origin, path, ignored) == "clear" then
			shot.arc = arc :: "low" | "medium"
			break
		end
	end
	chosen.projectile = shot
	return chosen
end

-- How far `weapon` reaches from `origin` at something at `target_position`. What arcs reaches further from above its
-- target and less far from below it.
local function reach_at(weapon: types.Weapon, origin: Vector3, target_position: Vector3): number
	local params = weapon.projectile
	if params ~= nil and params.arc ~= nil then
		return projectile.range_to(weapon.range, origin, target_position, params)
	end
	return weapon.range
end

-- Whether `weapon` can be turned on `target` at all. A weapon that names a layer shoots only at that one,
-- and a lobbed shell comes down where its target was, so it is never thrown at something in the air.
local function can_target(weapon: types.Weapon, target: Entity): boolean
	local in_air = unit_defs.is_air(unit_defs.get(target.def_name))
	if weapon.target_layer == "air" then
		return in_air
	end
	if weapon.target_layer == "ground" then
		return in_air == false
	end
	return in_air == false or is_lobbed(weapon) == false
end

-- What `attacker` shoots at when it fires from `origin`: the highest reward enemy in range it has a clear
-- shot at, skipping any target already `claimed`. Reward score is the unit's power (metal cost + 60x energy
-- cost) divided by its max health, so targets closest to dying get priority. With none it holds fire: a shot
-- that a friend is standing in is never taken on purpose. A weapon with a stockpile picks the same way as
-- any other once it has a missile ready - an order still overrides this, but nothing sits on a full silo
-- doing nothing just because nobody told it what to hit.
local function pick_target(attacker: Entity, origin: Vector3, weapon: types.Weapon, claimed: { EntityId }): Entity?
	if has_any_possible_enemy(attacker) == false then
		return nil
	end
	local lobbed = flies_over(weapon)
	local candidates: { Entity } = {}
	-- reach_at varies per candidate (an arced weapon reaches further from above its target than
	-- below it), so the grid is searched a little wider than the weapon's flat range and reach_at
	-- still gets the exact, final say per candidate below
	local search_radius = weapon.range * 1.25 + 100
	local own_root = alliances.root_of(attacker.team)
	each_within(attacker.position.X, attacker.position.Z, search_radius, own_root, function(other: Entity)
		if
			is_enemy(attacker, other)
			and can_target(weapon, other)
			and table.find(claimed, other.id) == nil
			and geometry.distance_2d(attacker.position, other.position) <= reach_at(weapon, origin, other.position)
		then
			table.insert(candidates, other)
		end
	end)
	table.sort(candidates, function(a: Entity, b: Entity): boolean
		-- Calculate power score: metal_cost + 60 * energy_cost
		local def_a = unit_defs.get(a.def_name)
		local def_b = unit_defs.get(b.def_name)
		local power_a = def_a.metal_cost + 60 * def_a.energy_cost
		local power_b = def_b.metal_cost + 60 * def_b.energy_cost
		-- Calculate reward score: power / current health (targets closer to dying get priority)
		local reward_a = power_a / a.health
		local reward_b = power_b / b.health
		-- Sort by highest reward first
		if reward_a ~= reward_b then
			return reward_a > reward_b
		end
		-- Tiebreaker: closest distance
		return geometry.distance_2d(attacker.position, a.position) < geometry.distance_2d(attacker.position, b.position)
	end)

	for index, other in candidates do
		if index > MAX_SIGHT_CHECKS then
			break
		end
		if lobbed or verdict_at(attacker, weapon, other, origin) == "clear" then
			return other
		end
	end
	return nil
end

-- pick_target, but reused for the rest of the tick if something else already asked the same
-- question for this attacker and weapon with nothing claimed - see pick_target_cache above. A dead
-- or gone result is never reused: the cache only ever holds what was true the moment it was made,
-- and something dying between the two calls that share it (rare, but a shot landing between them can
-- do it) is exactly the case a fresh pick_target must catch.
local function cached_pick_target(attacker: Entity, origin: Vector3, weapon: types.Weapon, claimed: { EntityId }): Entity?
	if #claimed > 0 then
		return pick_target(attacker, origin, weapon, claimed)
	end
	local by_weapon = pick_target_cache[attacker.id]
	if by_weapon == nil then
		by_weapon = {}
		pick_target_cache[attacker.id] = by_weapon
	end
	local cached = by_weapon[weapon]
	if cached ~= nil then
		if cached == false then
			return nil
		end
		if cached.alive then
			return cached
		end
	end
	local result = pick_target(attacker, origin, weapon, claimed)
	by_weapon[weapon] = if result ~= nil then result else false
	return result
end

-- Defined below, after the damage it deals, which can kill something that explodes in turn.
local explode: (source: Entity) -> ()

local function kill(entity: Entity, severity: number)
	-- Only finished things leave anything behind: a blueprint that dies just disappears, and so does what a
	-- death was too violent to leave a wreck of.
	-- a drone is only a part of its carrier and leaves nothing
	if
		entity.kind ~= "wreck"
		and entity.state == "active"
		and not air.is_aircraft(entity)
		and unit_defs.get(entity.def_name).drone ~= true
		and severity <= WRECK_MAX_SEVERITY
	then
		local wreck = state.create_wreck(entity)
	end
	state.mark_dead(entity)
	explode(entity)
end

local function apply_damage(target: Entity, amount: number)
	target.health -= amount
	recent_damage[target.id] = (recent_damage[target.id] or 0) + amount
	if target.health > 0 then
		return
	end
	local severity = recent_damage[target.id] / target.max_health * 100
	recent_damage[target.id] = nil
	kill(target, severity)
end

-- Something with a death explosion goes up when it dies: everything within its radius takes damage,
-- most at the centre and a quarter as much at the very edge. It hits friend and foe alike, and other
-- things that die to it can explode in their turn. It is called once the source is already marked dead,
-- so the source is not part of its own blast.
explode = function(source: Entity)
	-- a wreck that is destroyed just disappears: it keeps the def of what it was, but nothing of that goes off
	if source.kind == "wreck" then
		return
	end
	local blast = unit_defs.get(source.def_name).death_explosion
	if blast == nil or source.state ~= "active" then
		return
	end

	weapon_fired:FireAllClients({
		from = source.position,
		to = source.position,
		team = source.team,
		explosion = blast.radius,
	})
	deformation.crater(source.position, blast.radius, blast.damage)

	for _, other in state.all() do
		-- a blast on the ground does not reach an aircraft that is up in the air
		if other.alive == false or air.is_airborne(other) then
			continue
		end
		local reach = unit_defs.collider_radius(unit_defs.get(other.def_name))
		local distance = geometry.distance_2d(source.position, other.position)
		if distance <= blast.radius + reach then
			local falloff = 1 - 0.75 * math.clamp(distance / blast.radius, 0, 1)
			apply_damage(other, blast.damage * falloff)
		end
	end
end

-- `weapon` hits `struck`: it takes the weapon's damage, or a fraction of it if it is an aircraft and the
-- weapon is not dedicated anti air. The unit also loses acceleration for a short time due to the impact.
local function hit(struck: Entity, weapon: types.Weapon)
	local def = unit_defs.get(struck.def_name)
	apply_damage(struck, unit_defs.damage_against(weapon.anti_air == true, def, weapon.damage))
	-- Apply impulse/stun to reduce acceleration for ~0.5 seconds
	if def.max_speed ~= nil and def.acceleration ~= nil then
		movement.set_impulse(struck, 0.5)
	end
end

-- Pays the energy a shot costs, and says whether it could be paid.
local function pay_for_shot(attacker: Entity, weapon: types.Weapon): boolean
	if weapon.energy_per_shot > 0 and economy.try_spend(attacker.team, 0, weapon.energy_per_shot) == false then
		starved_at[attacker.id] = os.clock()
		return false
	end
	return true
end

-- Fires `weapon` from `origin` at `target`, and returns whether it went off. A rocket is launched at the
-- target and hits whatever it meets on the way. Anything else strikes the first solid thing on the line
-- to the target, which is the target itself unless something stands between.
local function fire(attacker: Entity, target: Entity, weapon: types.Weapon, origin: Vector3): boolean
	if pay_for_shot(attacker, weapon) == false then
		return false
	end

	if weapon.projectile ~= nil then
		projectiles.launch(
			attacker,
			origin,
			target.position,
			with_chosen_arc(attacker, weapon, origin, target.position, target.id),
			target.velocity,
			target
		)
		return true
	end

	local struck = los(sight.first_hit, attacker, target, origin)
	weapon_fired:FireAllClients({
		from = origin,
		to = struck.position,
		team = attacker.team,
		beam_time = weapon.beam_time,
		beam_thickness = weapon.beam_thickness,
		beam_color = weapon.beam_color,
	})
	hit(struck, weapon)
	return true
end

-- Fires `weapon` from `origin` at a bare `point` on the ground. A rocket is launched at the point, and
-- comes down there unless it meets something first. Anything else strikes the first solid thing on the
-- line to the point, and if there is nothing the shot goes into the ground.
local function fire_at_ground(attacker: Entity, point: Vector3, weapon: types.Weapon, origin: Vector3): boolean
	if pay_for_shot(attacker, weapon) == false then
		return false
	end

	if weapon.projectile ~= nil then
		projectiles.launch(attacker, origin, point, with_chosen_arc(attacker, weapon, origin, point, attacker.id), nil, nil)
		return true
	end

	local struck = los(sight.first_hit_at, attacker, point, origin)
	weapon_fired:FireAllClients({
		from = origin,
		to = if struck ~= nil then struck.position else point,
		team = attacker.team,
		beam_time = weapon.beam_time,
		beam_thickness = weapon.beam_thickness,
		beam_color = weapon.beam_color,
	})
	if struck ~= nil then
		hit(struck, weapon)
	end
	return true
end

-- The target an attack order names for `attacker`, if it can be shot with `weapon` right now.
local function forced_target(attacker: Entity, weapon: types.Weapon, origin: Vector3): Entity?
	local forced_id = locked[attacker.id]
	if forced_id == nil then
		return nil
	end
	local forced = state.get(forced_id)
	if
		forced == nil
		or is_valid_forced_target(attacker, forced) == false
		or can_target(weapon, forced) == false
		or geometry.distance_2d(attacker.position, forced.position) > reach_at(weapon, origin, forced.position)
	then
		return nil
	end
	-- an ordered target is held to the same rules: it is shot only when it can be seen
	if flies_over(weapon) or verdict_at(attacker, weapon, forced, origin) == "clear" then
		return forced
	end
	return nil
end

-- The point an attack-ground order names for `attacker`, if it can be shot at with `weapon` right now.
local function forced_point(attacker: Entity, weapon: types.Weapon, origin: Vector3): Vector3?
	local point = locked_ground[attacker.id]
	if
		point == nil
		or weapon.target_layer == "air"
		or geometry.distance_2d(attacker.position, point) > reach_at(weapon, origin, point)
	then
		return nil
	end
	if flies_over(weapon) or verdict_at_point(attacker, weapon, point, origin) == "clear" then
		return point
	end
	return nil
end

-- Picks a shot for `weapon` and takes it: the point or the target an attack order names if it can be shot
-- now, and otherwise the nearest enemy that can be seen, preferring one that is not `claimed`. Returns
-- whether the shot went off, and the entity it was at, if it was at one. Anti-nuke weapons search for
-- nuclear missiles in flight instead of targeting entities.
local function shoot(
	attacker: Entity,
	weapon: types.Weapon,
	origin: Vector3,
	claimed: { EntityId }
): (boolean, EntityId?)
	-- anti-nuke weapons search for nuclear missiles to intercept instead of targeting entities
	if weapon.anti_nuke == true then
		local nuke = projectiles.pick_nuke_target(origin, attacker.team, weapon.range)
		if nuke ~= nil then
			-- fire at the nuke's current position as if it were a ground target
			return fire_at_ground(attacker, nuke.flight.position, weapon, origin), nil
		end
		return false, nil
	end

	local point = forced_point(attacker, weapon, origin)
	if point ~= nil then
		return fire_at_ground(attacker, point, weapon, origin), nil
	end

	local target = forced_target(attacker, weapon, origin)
	if target == nil then
		target = cached_pick_target(attacker, origin, weapon, claimed)
	end
	-- take a target another weapon is already shooting over none
	if target == nil and #claimed > 0 then
		target = cached_pick_target(attacker, origin, weapon, {})
	end
	if target == nil then
		return false, nil
	end
	return fire(attacker, target, weapon, origin), target.id
end

-- Runs each of an entity's turrets on its own: its own reload, its own choice of target, and its own
-- origin for the shot. A turret that is reloading is left alone, and one that finds nothing in range
-- simply waits, without holding up the others.
--
-- A turret marked `shares_main_reload` has no reload of its own: it reads the entity's main weapon
-- reload instead, and only ever fires while that is at zero. The decrementing happens once, in the
-- main weapon's own reload block below (which runs after this), so it is not repeated here - this
-- only reads it to decide whether the shared turret may fire this tick, and sets it (to its own
-- weapon's reload time) when it does, which is what stops the main weapon from also firing this tick.
local function tick_turrets(entity: Entity, turrets: { types.Turret }, delta: number)
	local claimed: { EntityId } = {}
	local frame = CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0)

	for index, turret in turrets do
		-- initialize burst tracking array if needed
		if entity.turret_burst_remaining[index] == nil then
			entity.turret_burst_remaining[index] = 0
		end

		local shared = turret.shares_main_reload == true
		if shared then
			if entity.reload_remaining > 0 then
				continue
			end
		else
			local remaining = entity.turret_reloads[index]
			if remaining ~= nil and remaining > 0 then
				entity.turret_reloads[index] = math.max(0, remaining - delta)
				continue
			end
		end

		local weapon = turret.weapon
		local origin = frame:PointToWorldSpace(turret.offset)
		-- prefer a target the other turrets are not already shooting, but take the same one over none
		local fired, at = shoot(entity, weapon, origin, claimed)
		if fired then
			-- handle burst fire logic for turret: the short gap between shots in a burst, or the full
			-- reload once it completes
			local reload_time = weapon.reload
			if weapon.burst_count ~= nil and weapon.burst_count > 1 then
				entity.turret_burst_remaining[index] += 1
				if entity.turret_burst_remaining[index] >= weapon.burst_count then
					entity.turret_burst_remaining[index] = 0
				else
					reload_time = weapon.burst_interval or DEFAULT_BURST_INTERVAL
				end
			end
			if shared then
				entity.reload_remaining = reload_time
			else
				entity.turret_reloads[index] = reload_time
			end
			if at ~= nil then
				table.insert(claimed, at)
			end
		end
	end
end

-- Whether `entity` has something it could shoot at this moment: an enemy within range of any of its
-- weapons that it has a clear line to, whether or not the weapon is reloading. It is what makes a unit on a
-- fight order stop walking.
local function has_target(entity: Entity): boolean
	local def = unit_defs.get(entity.def_name)
	if def.weapon ~= nil and cached_pick_target(entity, sight.muzzle_of(entity), def.weapon, {}) ~= nil then
		return true
	end
	if def.turrets ~= nil then
		local frame = CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0)
		for _, turret in def.turrets do
			if cached_pick_target(entity, frame:PointToWorldSpace(turret.offset), turret.weapon, {}) ~= nil then
				return true
			end
		end
	end
	return false
end

-- What came of trying to fire a manual weapon: it "fired"; it is "waiting", for its reload or for energy, and
-- can be tried again; it is "blocked", by a commander in the way, which is no better a moment later; or the
-- shooter is "unable" to, being dead, unfinished or without one.
export type ManualFireResult = "fired" | "waiting" | "blocked" | "unable"

-- Fires an entity's manual weapon toward `aim`. A rectangle sweeps out from the shooter along that
-- line for the weapon's whole range, and everything inside it except the shooter is destroyed
-- outright, with no wreck: it is disintegrated, whoever it belonged to. Anything that even touches
-- the rectangle goes, so each thing counts as a circle its collider wide.
local function manual_fire(shooter: Entity, aim: Vector3): ManualFireResult
	if shooter.alive == false or shooter.state ~= "active" then
		return "unable"
	end
	local weapon = unit_defs.get(shooter.def_name).manual_weapon
	if weapon == nil then
		return "unable"
	end
	if shooter.manual_reload_remaining > 0 then
		return "waiting"
	end

	-- straight ahead if it was aimed at the shooter itself
	local direction = geometry.flatten(aim - shooter.position)
	if direction.Magnitude < 1e-3 then
		direction = Vector3.new(math.sin(shooter.facing), 0, math.cos(shooter.facing))
	else
		direction = direction.Unit
	end
	local sideways = Vector3.new(-direction.Z, 0, direction.X)

	-- Which of the others the rectangle touches. Each counts as a circle its collider wide.
	local inside = {}
	for _, other in state.all() do
		-- it sweeps the ground, so an aircraft that is up in the air is over it
		if other.alive == false or other.id == shooter.id or air.is_airborne(other) then
			continue
		end
		local reach = unit_defs.collider_radius(unit_defs.get(other.def_name))
		local offset = geometry.flatten(other.position - shooter.position)
		local along = offset:Dot(direction)
		local across = math.abs(offset:Dot(sideways))
		if along >= -reach and along <= weapon.range + reach and across <= weapon.radius + reach then
			-- a commander in the way blocks the shot entirely: nothing is fired, nothing is spent
			if other.def_name == "commander" then
				return "blocked"
			end
			table.insert(inside, other)
		end
	end

	if economy.try_spend(shooter.team, 0, weapon.energy_per_shot) == false then
		return "waiting"
	end
	shooter.manual_reload_remaining = weapon.reload

	local far = shooter.position + direction * weapon.range
	weapon_fired:FireAllClients({
		from = shooter.position,
		to = heightmap.ground_position(far.X, far.Z),
		team = shooter.team,
		radius = weapon.radius,
	})

	for _, other in inside do
		state.mark_dead(other)
		-- disintegrated, but not defused
		explode(other)
	end
	return "fired"
end

-- `target_id` is the target an attack order named, if any. It replaces a point named by an attack-ground
-- order, and so does nil, which is what every other kind of order sets.
local function set_forced_target(attacker: Entity, target_id: EntityId?)
	locked_ground[attacker.id] = nil
	if target_id == nil then
		locked[attacker.id] = nil
	else
		locked[attacker.id] = target_id
	end
end

-- `point` is the spot an attack-ground order named. It replaces any target.
local function set_forced_ground(attacker: Entity, point: Vector3)
	locked[attacker.id] = nil
	locked_ground[attacker.id] = point
end

-- Works on the next missile of a stockpile: it is finished once its time is up and its price can be paid
-- incrementally as progress accumulates. Resources are drained proportionally to progress each frame, so
-- that the full cost is paid by the time the missile is complete. Nothing is made once the stockpile is full.
local function grow_stockpile(entity: Entity, stockpile: types.Stockpile, delta: number)
	if entity.stockpile >= stockpile.limit then
		entity.stockpile_progress = 0
		stockpile_progress_previous[entity.id] = 0
		return
	end

	-- Track previous progress to calculate incremental resource drain
	local previous_progress = stockpile_progress_previous[entity.id] or 0
	entity.stockpile_progress = math.min(stockpile.build_time, entity.stockpile_progress + delta)

	-- Calculate how much progress accumulated this frame and drain resources incrementally
	local progress_delta = entity.stockpile_progress - previous_progress
	if progress_delta > 0 then
		-- Calculate proportional resource cost for this frame's progress
		local metal_per_build_time = stockpile.metal / stockpile.build_time
		local energy_per_build_time = stockpile.energy / stockpile.build_time
		local metal_to_drain = progress_delta * metal_per_build_time
		local energy_to_drain = progress_delta * energy_per_build_time

		-- Try to spend resources incrementally
		if economy.try_spend(entity.team, metal_to_drain, energy_to_drain) then
			stockpile_progress_previous[entity.id] = entity.stockpile_progress
		else
			-- If we can't afford this frame's progress, revert progress and stop building
			entity.stockpile_progress = previous_progress
			return
		end
	end

	-- Once progress reaches build_time, increment the stockpile
	if entity.stockpile_progress >= stockpile.build_time then
		entity.stockpile += 1
		entity.stockpile_progress = 0
		stockpile_progress_previous[entity.id] = 0
	end
end

-- Determines the reload time after a shot is fired for a burst weapon. If the weapon has bursts,
-- returns the burst shot interval if more shots remain in the burst, or the full reload time before
-- the next burst starts. For non-burst weapons, returns the normal reload time.
local function burst_reload(weapon: types.Weapon, shots_fired_in_burst: number): number
	if weapon.burst_count == nil or weapon.burst_count <= 1 then
		return weapon.reload
	end
	-- If we've fired the full burst, use full reload time; otherwise use the reload interval between shots
	if shots_fired_in_burst >= weapon.burst_count then
		return weapon.reload
	end
	-- Use reload time between shots in burst (assumed to be the same as reload)
	return weapon.reload
end

-- Rebuilds the target grid and clears the pick_target cache for the tick about to run - called
-- before orders.tick() (see init.server.luau), so a fight order's has_target check and this same
-- tick's actual shot both see one fresh grid and share one cached result per (attacker, weapon).
local function begin_tick()
	rebuild_target_grid()
	table.clear(pick_target_cache)
end

local function tick(delta: number)
	local decay = RECENT_DAMAGE_DECAY ^ (delta * FRAMES_PER_SECOND)
	for id, damage in recent_damage do
		if damage * decay < 1e-3 or state.get(id) == nil then
			recent_damage[id] = nil
		else
			recent_damage[id] = damage * decay
		end
	end
	for _, entity in state.all() do
		-- a wreck is what a unit leaves behind and keeps its def, but nothing of it fires
		if entity.alive == false or entity.state ~= "active" or entity.kind == "wreck" then
			continue
		end
		-- a drone parked on its carrier holds its fire
		if docking.is_docked(entity.id) then
			continue
		end
		if entity.manual_reload_remaining > 0 then
			entity.manual_reload_remaining = math.max(0, entity.manual_reload_remaining - delta)
		end

		local def = unit_defs.get(entity.def_name)
		if def.turrets ~= nil then
			tick_turrets(entity, def.turrets, delta)
		end
		local weapon = def.weapon
		if weapon == nil then
			continue
		end
		if weapon.stockpile ~= nil then
			grow_stockpile(entity, weapon.stockpile, delta)
		end

		if entity.reload_remaining > 0 then
			entity.reload_remaining = math.max(0, entity.reload_remaining - delta)
			continue
		end
		-- nothing to fire until a missile is ready
		if weapon.stockpile ~= nil and entity.stockpile < 1 then
			continue
		end

		if shoot(entity, weapon, sight.muzzle_of(entity), {}) then
			-- handle burst fire logic
			if weapon.burst_count ~= nil and weapon.burst_count > 1 then
				entity.burst_remaining += 1
				if entity.burst_remaining >= weapon.burst_count then
					-- burst complete, full reload time before the next one starts
					entity.reload_remaining = weapon.reload
					entity.burst_remaining = 0
				else
					-- more shots left in this burst, so only the short gap between them applies
					entity.reload_remaining = weapon.burst_interval or DEFAULT_BURST_INTERVAL
				end
			else
				-- no burst, standard reload
				entity.reload_remaining = weapon.reload
			end
			if weapon.stockpile ~= nil then
				entity.stockpile -= 1
				launched[entity.id] = true
			end
		end
	end
end

-- Whether the shooter has just been unable to fire for want of energy. It stays true for a moment after
-- the last failed shot, and a shooter that is short keeps trying every tick, so while it is short it holds.
local function short_of_energy(entity_id: EntityId): boolean
	local at = starved_at[entity_id]
	return at ~= nil and os.clock() - at < STARVED_SHOWN_FOR
end

-- Whether `entity_id` has launched a stockpiled missile since this was last asked. An attack order that
-- launches one is done, and asks so that it can end.
local function take_launch(entity_id: EntityId): boolean
	local was = launched[entity_id] == true
	launched[entity_id] = nil
	return was
end

local function forget(entity_id: EntityId)
	launched[entity_id] = nil
	locked[entity_id] = nil
	locked_ground[entity_id] = nil
	starved_at[entity_id] = nil
	stockpile_progress_previous[entity_id] = nil
end

return table.freeze({
	begin_tick = begin_tick,
	tick = tick,
	apply_damage = apply_damage,
	manual_fire = manual_fire,
	set_forced_target = set_forced_target,
	set_forced_ground = set_forced_ground,
	is_enemy = is_enemy,
	is_valid_forced_target = is_valid_forced_target,
	can_target = can_target,
	has_target = has_target,
	take_launch = take_launch,
	forget = forget,
	short_of_energy = short_of_energy,
})
