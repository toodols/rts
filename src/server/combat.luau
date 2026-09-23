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
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local art = require(ReplicatedStorage.Shared.art)
local geometry = require(ReplicatedStorage.Shared.geometry)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local projectile = require(ReplicatedStorage.Shared.projectile)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local stockpiles = require(script.Parent.stockpiles)
local sight = require(script.Parent.sight)
local alliances = require(script.Parent.alliances)
local docking = require(script.Parent.docking)
local projectiles = require(script.Parent.projectiles)
local air = require(script.Parent.air)
local deformation = require(script.Parent.deformation)
local movement = require(script.Parent.movement)
local profiler = require(script.Parent.profiler)
local turrets = require(script.Parent.turrets)

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

-- A bomber searches for targets as far ahead as a bomb would carry falling to ground this much lower than what it
-- is over.
local DROP_SEARCH_DEPTH = 20

-- Target acquisition scans a flat (X, Z) grid instead of every living thing, the same idea as
-- movement's separation: rebuilt once a tick (see `rebuild_target_grid`), a search only visits the
-- cells within a weapon's own reach instead of the whole map. Most weapons reach nowhere near far
-- enough to make that expensive; the rare ones that do (a nuclear silo's whole-map range, say) just
-- fall back to the plain scan below, since at that range almost everything is a candidate cell
-- anyway and partitioning buys nothing.
--
-- The cell is small next to typical weapon ranges on purpose: the search visits whole cells, so the
-- square it covers overshoots the weapon's reach circle by up to a cell on every side, and every
-- entity in that overshoot is visited and rejected on every scan.
local TARGET_CELL = 64
-- Past this many rings out from the shooter, the grid is visiting more empty cells than it is
-- saving real work, so pick_target falls back to a plain scan instead.
local TARGET_GRID_MAX_RINGS = 16

-- Each cell buckets its entities again by alliance root (alliances.root_of), not just by position: two
-- entities can only be enemies if their roots differ, so a search for `attacker`'s targets can skip
-- straight past its own root's bucket in every cell it visits, rather than visiting every nearby
-- friend and rejecting each one with is_enemy. In a crowd that is mostly or entirely one side - a solo
-- army with nobody around to fight, or just everyone's own front line - that is most of the cell.
type TargetCell = { [number]: { Entity } }
type TargetGrid = { [number]: { [number]: TargetCell } }

local target_grid: TargetGrid = {}

-- pick_target's result for (attacker, weapon), cached for the rest of the tick it was computed in, so
-- nothing asks the same question twice in one tick. any_target (a fight order's has_target) reads it,
-- and writes `false` into it when nothing at all is in reach, which spares shoot() the same fruitless
-- scan moments later. Only valid when `claimed` is empty, so a turret already skipping a claimed
-- target always computes fresh. Cleared in begin_tick(), which runs before orders.tick(), so it holds
-- for the whole tick.
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
		-- a reclaimable is never anything's target, even by force, so it is left out of the search altogether
		if entity.alive == false or entity.kind == "reclaimable" then
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
-- A visit that returns true ends the search there.
local function each_within(x: number, z: number, radius: number, own_root: number, visit: (Entity) -> boolean?)
	local rings = math.ceil(radius / TARGET_CELL)
	if rings > TARGET_GRID_MAX_RINGS then
		for _, entity in state.all() do
			if entity.alive and alliances.root_of(entity.team) ~= own_root then
				if visit(entity) == true then
					return
				end
			end
		end
		return
	end
	local cx, cz = target_cell_of(x, z)
	local radius_squared = radius * radius
	for gx = cx - rings, cx + rings do
		local column = target_grid[gx]
		-- how far (x, z) is from this column of cells along X, zero if it is inside it
		local cell_min_x = gx * TARGET_CELL
		local dx = math.max(cell_min_x - x, 0, x - (cell_min_x + TARGET_CELL))
		if column ~= nil and dx * dx <= radius_squared then
			for gz = cz - rings, cz + rings do
				local cell = column[gz]
				local cell_min_z = gz * TARGET_CELL
				local dz = math.max(cell_min_z - z, 0, z - (cell_min_z + TARGET_CELL))
				-- a cell whose nearest point is out past the radius - the corners of the square, mostly -
				-- has nothing in it that could be in reach
				if cell ~= nil and dx * dx + dz * dz <= radius_squared then
					for root, bucket in cell do
						if root ~= own_root then
							for _, entity in bucket do
								if visit(entity) == true then
									return
								end
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
-- The most shots one weapon takes in a tick, when its reload is shorter than a tick.
local MAX_SHOTS_PER_TICK = 16

-- Locked targets, kept outside Entity so the record stays flat.
local locked: { [EntityId]: EntityId } = {}
-- Points on the ground that shooters were ordered to attack; a shooter has one of these or a locked
-- target, never both.
local locked_ground: { [EntityId]: Vector3 } = {}
-- What a bomber let the first bomb of its current burst go at, by weapon: the target, if it was one, and
-- where it was. The rest of the burst goes at the same. Keyed by the `Weapon` table itself, the same way
-- pick_target_cache is, so two bomb-carrying weapons on one entity never share a slot.
local burst_aims: { [EntityId]: { [types.Weapon]: { target: Entity?, point: Vector3 } } } = {}

-- Shooters that have launched a stockpiled missile since their orders last looked, which is what ends the attack
-- order that told them to.
local launched: { [EntityId]: boolean } = {}

-- When each shooter last had a target and could not pay for the shot, so that it can say so.
local STARVED_SHOWN_FOR = 0.4
local starved_at: { [EntityId]: number } = {}

-- A laser's beam stays up for its `beam_time`, and deals its damage over that time rather than all at once when it
-- fires: a slice every tick, the first as it fires. Each slice after the first is aimed again from where the shooter
-- is at what it was fired at, and strikes the first solid thing on that line, as the first did, so a friend that
-- walks into the beam takes the rest of it. It goes out when the shooter dies or its target does, or the target gets
-- out of reach, and what was left of it is lost.
type Beam = {
	shooter_id: EntityId,
	weapon: types.Weapon,
	-- what it was fired at: a target, or for an attack-ground order a bare point
	target_id: EntityId?,
	point: Vector3?,
	slices_left: number,
	slice: number,
}
local beams: { Beam } = {}

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
-- missile leaves straight up, so nothing in front of it matters either, and nor does it for a bomb, which falls
-- from above everything.
local function flies_over(weapon: types.Weapon): boolean
	return weapon.projectile ~= nil
		and (
			weapon.projectile.arc == "high"
			or weapon.projectile.arc == "medium"
			or weapon.projectile.arc == "auto"
			or weapon.projectile.missile ~= nil
			or weapon.projectile.dropped == true
		)
end

local function is_dropped(weapon: types.Weapon): boolean
	return weapon.projectile ~= nil and weapon.projectile.dropped == true
end

local function is_torpedo(weapon: types.Weapon): boolean
	return weapon.projectile ~= nil and weapon.projectile.torpedo == true
end

-- How far apart the points along a torpedo's way are checked for water deep enough to carry it.
local TORPEDO_PATH_SPACING = 4

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

-- Whether `weapon` fires its shots one after another in bursts, a short gap apart, before its full reload.
local function fires_in_bursts(weapon: types.Weapon): boolean
	return weapon.burst_count ~= nil and weapon.burst_count > 1
end

-- How near the target the first bomb of a burst has to be going to come down for `attacker` to start it: half the
-- length of the line of bombs the burst lays along its path, as in BAR, so that the target is in the middle of the
-- line, the first bombs coming down short of it and the last ones past it. A weapon with no burst takes it as the
-- ground covered in one gap between shots.
local function drop_window(attacker: Entity, weapon: types.Weapon): number
	local gaps = math.max(1, (weapon.burst_count or 1) - 1)
	local interval = weapon.burst_interval or DEFAULT_BURST_INTERVAL
	return gaps * interval * geometry.flatten(attacker.velocity).Magnitude / 2
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

-- Whether `attacker` has a shot at `target` with `weapon` from `origin`: a torpedo needs water all the way there,
-- a shell that flies over what is in the way needs nothing, and anything else needs a clear line. Nothing but a
-- torpedo is fired from under the water, as nothing but a torpedo is fired at what is under it.
local function has_shot(attacker: Entity, weapon: types.Weapon, target: Entity, origin: Vector3): boolean
	if is_torpedo(weapon) then
		return through_water(origin, target.position)
	end
	if origin.Y < config.WATER_LEVEL then
		return false
	end
	return flies_over(weapon) or verdict_at(attacker, weapon, target, origin) == "clear"
end

-- The same for a bare point. A torpedo can only be sent at one in water it can run in.
local function has_shot_at_point(attacker: Entity, weapon: types.Weapon, point: Vector3, origin: Vector3): boolean
	if is_torpedo(weapon) then
		return projectile.torpedo_runs_at(point.X, point.Z) and through_water(origin, point)
	end
	if origin.Y < config.WATER_LEVEL then
		return false
	end
	return flies_over(weapon) or verdict_at_point(attacker, weapon, point, origin) == "clear"
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

-- Whether `weapon`, fired by `attacker` from `origin`, reaches something at `position` moving at `velocity`, which
-- is `distance` from `attacker` along the ground. A bomb reaches only what it would come down within the drop
-- window of.
local function reaches(
	attacker: Entity,
	weapon: types.Weapon,
	origin: Vector3,
	position: Vector3,
	velocity: Vector3,
	distance: number
): boolean
	local params = weapon.projectile
	if params ~= nil and params.dropped == true then
		return drop_miss(attacker, params, origin, position, velocity) < drop_window(attacker, weapon)
	end
	return distance <= reach_at(weapon, origin, position)
end

-- How far out a target search for `weapon` has to look. reach_at varies per candidate only for an
-- arced weapon (it reaches further from above its target than below it), so only that needs searching
-- a little wider than its flat range, with reach_at still getting the exact, final say per candidate;
-- anything else reaches exactly its range, and every stud past that is entities visited for nothing. A bomb
-- reaches its drop window around where it comes down, which is ahead of the bomber by as far as it carries.
local function search_radius_of(attacker: Entity, weapon: types.Weapon, origin: Vector3): number
	local params = weapon.projectile
	if params ~= nil and params.arc ~= nil then
		return weapon.range * 1.25 + 100
	end
	if params ~= nil and params.dropped == true then
		local floor = heightmap.height_at(origin.X, origin.Z) - DROP_SEARCH_DEPTH
		local lands = projectile.fall_time(origin, attacker.velocity, params.gravity, floor)
		return drop_window(attacker, weapon) + geometry.flatten(attacker.velocity).Magnitude * lands
	end
	return weapon.range
end

-- Whether `weapon` can be turned on `target` at all. A torpedo is aimed at what is in the water and nothing else, and
-- is the only thing that is aimed at what is wholly under it. A weapon that names a layer shoots only at that one,
-- and a lobbed shell comes down where its target was, so it is never thrown at something in the air.
local function can_target(weapon: types.Weapon, target: Entity): boolean
	local def = unit_defs.get(target.def_name)
	if is_torpedo(weapon) then
		return unit_defs.in_water(def, target.position)
	end
	if unit_defs.submerged(def, target.position) then
		return false
	end
	local in_air = unit_defs.is_air(def)
	if weapon.target_layer == "air" then
		return in_air
	end
	if weapon.target_layer == "ground" then
		return in_air == false
	end
	return in_air == false or is_lobbed(weapon) == false
end

-- What `attacker` shoots at when it fires from `origin`: the highest reward enemy in range it has a clear
-- shot at, skipping any target already `claimed`, scored as below. With none it holds fire: a shot
-- that a friend is standing in is never taken on purpose. A manual-fire weapon (`Weapon.manual_fire`) never picks
-- for itself, and fires only at what an order names.
local function pick_target(attacker: Entity, origin: Vector3, weapon: types.Weapon, claimed: { EntityId }): Entity?
	if has_any_possible_enemy(attacker) == false then
		return nil
	end
	local candidates: { Entity } = {}
	local search_radius = search_radius_of(attacker, weapon, origin)
	local own_root = alliances.root_of(attacker.team)
	each_within(attacker.position.X, attacker.position.Z, search_radius, own_root, function(other: Entity)
		-- distance first: out of reach is by far the most common reason to reject, and the cheapest
		local distance = geometry.distance_2d(attacker.position, other.position)
		if distance > search_radius then
			return nil
		end
		if
			is_enemy(attacker, other)
			and can_target(weapon, other)
			and table.find(claimed, other.id) == nil
			and reaches(attacker, weapon, origin, other.position, other.velocity, distance)
		then
			table.insert(candidates, other)
		end
		return nil
	end)
	-- The reward for shooting something is its power (metal cost + 60x energy cost) over its current health, so
	-- what is closest to dying comes first, times the share of the weapon's damage it would actually take: an
	-- aircraft that takes 15% from a weapon that is not anti air is worth 15% of what it would be to one that is.
	local rewards: { [Entity]: number } = {}
	local anti_air = weapon.anti_air == true
	for _, other in candidates do
		local def = unit_defs.get(other.def_name)
		local power = def.metal_cost + 60 * def.energy_cost
		rewards[other] = power * unit_defs.damage_against(anti_air, def, 1) / math.max(other.health, 1e-3)
	end
	table.sort(candidates, function(a: Entity, b: Entity): boolean
		local reward_a = rewards[a]
		local reward_b = rewards[b]
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
		if has_shot(attacker, weapon, other, origin) then
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
local function cached_pick_target(
	attacker: Entity,
	origin: Vector3,
	weapon: types.Weapon,
	claimed: { EntityId }
): Entity?
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

-- Whether `weapon` has anything at all it could fire on from `origin` right now - not which target is
-- best, which is what pick_target is for. A fight order asks this every tick just to decide whether to
-- stand or keep walking, while the unit only actually picks and fires once per reload, so paying for a
-- full scan-and-sort here was most of the cost of a battle. This stops at the first enemy in reach it
-- has a shot at, and, like pick_target, gives up once MAX_SIGHT_CHECKS of them turn out to be blocked.
-- Answers from pick_target's cache instead if something already worked the real answer out this tick.
local function any_target(attacker: Entity, origin: Vector3, weapon: types.Weapon): boolean
	local by_weapon = pick_target_cache[attacker.id]
	local cached = if by_weapon ~= nil then by_weapon[weapon] else nil
	if cached == false then
		return false
	elseif cached ~= nil and cached.alive then
		return true
	end
	if has_any_possible_enemy(attacker) == false then
		return false
	end
	local search_radius = search_radius_of(attacker, weapon, origin)
	local own_root = alliances.root_of(attacker.team)
	local found = false
	local blocked = 0
	each_within(attacker.position.X, attacker.position.Z, search_radius, own_root, function(other: Entity): boolean?
		-- distance first: out of reach is by far the most common reason to reject, and the cheapest
		local distance = geometry.distance_2d(attacker.position, other.position)
		if
			distance > search_radius
			or is_enemy(attacker, other) == false
			or can_target(weapon, other) == false
			or reaches(attacker, weapon, origin, other.position, other.velocity, distance) == false
		then
			return nil
		end
		if has_shot(attacker, weapon, other, origin) then
			found = true
			return true
		end
		blocked += 1
		return blocked >= MAX_SIGHT_CHECKS
	end)
	-- Nothing in reach at all means pick_target has no candidates either, so its answer is already
	-- known - and a shooter with nothing to shoot never starts a reload, so without this its own
	-- shoot() would pay for the same fruitless scan again this very tick.
	if found == false and blocked == 0 then
		if by_weapon == nil then
			by_weapon = {}
			pick_target_cache[attacker.id] = by_weapon
		end
		by_weapon[weapon] = false
	end
	return found
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
	-- a reclaimable has no health to speak of: nothing but reclaiming it takes it away
	if target.kind == "reclaimable" then
		return
	end
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

-- `weapon` hits `struck` for `amount` of damage, or a fraction of it if it is an aircraft and the weapon is not
-- dedicated anti air. The unit also loses acceleration for a short time due to the impact.
local function hit(struck: Entity, weapon: types.Weapon, amount: number)
	local def = unit_defs.get(struck.def_name)
	apply_damage(struck, unit_defs.damage_against(weapon.anti_air == true, def, amount))
	-- it answers slower for half a second (`movement.set_impulse`)
	if def.max_speed ~= nil and def.acceleration ~= nil then
		movement.set_impulse(struck, 0.5)
	end
end

-- How many ticks a beam of `weapon` burns for, and so how many slices its damage comes in: at least one, for a weapon
-- whose beam is up for less than a tick, or has no beam time at all.
local function beam_slices(weapon: types.Weapon): number
	return math.max(1, math.round((weapon.beam_time or 0) / config.TICK_DELTA))
end

-- Starts a beam of `weapon` from `attacker`, at a target or at a bare point, which has already struck `struck`, if
-- anything, with its first slice: the rest follow in the ticks after this one (see `tick_beams`).
local function burn(attacker: Entity, weapon: types.Weapon, struck: Entity?, target_id: EntityId?, point: Vector3?)
	local slices = beam_slices(weapon)
	local slice = weapon.damage / slices
	if struck ~= nil then
		hit(struck, weapon, slice)
	end
	if slices > 1 then
		table.insert(beams, {
			shooter_id = attacker.id,
			weapon = weapon,
			target_id = target_id,
			point = point,
			slices_left = slices - 1,
			slice = slice,
		})
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
-- target and hits whatever it meets on the way, `late` seconds into its flight already, for the part of this
-- tick since the weapon was ready. Anything else is a laser: its beam strikes the first solid thing on the line to
-- the target, which is the target itself unless something stands between, and goes on burning (see `burn`).
local function fire(attacker: Entity, target: Entity, weapon: types.Weapon, origin: Vector3, late: number): boolean
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
			target,
			late
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
	burn(attacker, weapon, struck, target.id, nil)
	return true
end

-- Fires `weapon` from `origin` at a bare `point` on the ground. A rocket is launched at the point, `late` seconds
-- into its flight as `fire` does, and comes down there unless it meets something first. Anything else strikes the
-- first solid thing on the line to the point, and if there is nothing the shot goes into the ground.
local function fire_at_ground(
	attacker: Entity,
	point: Vector3,
	weapon: types.Weapon,
	origin: Vector3,
	late: number
): boolean
	if pay_for_shot(attacker, weapon) == false then
		return false
	end

	if weapon.projectile ~= nil then
		projectiles.launch(
			attacker,
			origin,
			point,
			with_chosen_arc(attacker, weapon, origin, point, attacker.id),
			nil,
			nil,
			late
		)
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
	burn(attacker, weapon, struck, nil, point)
	return true
end

-- The target an attack order names for `attacker`, if it can be shot with `weapon` right now.
local function forced_target(attacker: Entity, weapon: types.Weapon, origin: Vector3): Entity?
	local forced_id = locked[attacker.id]
	if forced_id == nil then
		return nil
	end
	local forced = state.get(forced_id)
	if forced == nil or is_valid_forced_target(attacker, forced) == false or can_target(weapon, forced) == false then
		return nil
	end
	local distance = geometry.distance_2d(attacker.position, forced.position)
	if reaches(attacker, weapon, origin, forced.position, forced.velocity, distance) == false then
		return nil
	end
	-- an ordered target is held to the same rules: it is shot only when it can be seen
	if has_shot(attacker, weapon, forced, origin) then
		return forced
	end
	return nil
end

-- The point an attack-ground order names for `attacker`, if it can be shot at with `weapon` right now.
local function forced_point(attacker: Entity, weapon: types.Weapon, origin: Vector3): Vector3?
	local point = locked_ground[attacker.id]
	if point == nil or weapon.target_layer == "air" then
		return nil
	end
	local distance = geometry.distance_2d(attacker.position, point)
	if reaches(attacker, weapon, origin, point, Vector3.zero, distance) == false then
		return nil
	end
	if has_shot_at_point(attacker, weapon, point, origin) then
		return point
	end
	return nil
end

-- What `weapon` would shoot at now, if anything: a point on the ground, or a target. It is the point an
-- attack-ground order names or the target an attack order names if it can be shot now, and otherwise the nearest
-- enemy that can be seen, preferring one that is not `claimed`. An anti-nuke weapon looks for a nuclear missile in
-- flight instead, and gives where it is as the point.
export type Choice = {
	target: Entity?,
	point: Vector3?,
}

local function choose(attacker: Entity, weapon: types.Weapon, origin: Vector3, claimed: { EntityId }): Choice
	if weapon.anti_nuke == true then
		local nuke = projectiles.pick_nuke_target(origin, attacker.team, weapon.range)
		return { target = nil, point = if nuke ~= nil then nuke.flight.position else nil }
	end
	local point = forced_point(attacker, weapon, origin)
	if point ~= nil then
		return { target = nil, point = point }
	end
	local target = forced_target(attacker, weapon, origin)
	-- a manual-fire weapon shoots at what it is told to and nothing else
	if target == nil and weapon.manual_fire == true then
		return { target = nil, point = nil }
	end
	if target == nil then
		target = cached_pick_target(attacker, origin, weapon, claimed)
	end
	-- take a target another weapon is already shooting over none
	if target == nil and #claimed > 0 then
		target = cached_pick_target(attacker, origin, weapon, {})
	end
	return { target = target, point = nil }
end

-- Picks a shot for `weapon` and takes it: what `choose` picks, or `chosen` when that has already been made (for a
-- turret, which fires at what it has turned to face). Returns whether the shot went off, and the entity it was at,
-- if it was at one. `mid_burst` says the weapon has already fired the first shot of a burst, and `late` is how
-- long ago in this tick it was ready to fire (see `fire`).
local function shoot(
	attacker: Entity,
	weapon: types.Weapon,
	origin: Vector3,
	claimed: { EntityId },
	mid_burst: boolean,
	late: number,
	chosen: Choice?
): (boolean, EntityId?)
	-- anti-nuke weapons search for nuclear missiles to intercept instead of targeting entities
	if weapon.anti_nuke == true then
		local nuke_point = (chosen or choose(attacker, weapon, origin, claimed)).point
		if nuke_point ~= nil then
			-- fire at the nuke's current position as if it were a ground target
			return fire_at_ground(attacker, nuke_point, weapon, origin, late), nil
		end
		return false, nil
	end
	local dropped = is_dropped(weapon)
	-- a bomb is only let go from the air: a bomber sitting on the ground holds on to it
	if dropped and air.is_airborne(attacker) == false then
		return false, nil
	end
	-- A bomber's burst is one shot: the first bomb is let go when the target is in the drop window, and the rest
	-- follow it at what the first was let go at, whatever they will come down on, short of it and then past it.
	local by_weapon_aim = burst_aims[attacker.id]
	local aim = if by_weapon_aim ~= nil then by_weapon_aim[weapon] else nil
	if dropped and mid_burst and aim ~= nil then
		local aimed = if aim.target ~= nil and aim.target.alive then aim.target else nil
		if aimed ~= nil then
			return fire(attacker, aimed, weapon, origin, late), aimed.id
		end
		return fire_at_ground(attacker, aim.point, weapon, origin, late), nil
	end

	local choice = chosen or choose(attacker, weapon, origin, claimed)
	local point = choice.point
	if point ~= nil then
		if dropped then
			if by_weapon_aim == nil then
				by_weapon_aim = {}
				burst_aims[attacker.id] = by_weapon_aim
			end
			by_weapon_aim[weapon] = { target = nil, point = point }
		end
		return fire_at_ground(attacker, point, weapon, origin, late), nil
	end

	local target = choice.target
	-- a turret's target can die to an earlier shot this same tick
	if target == nil or target.alive == false then
		return false, nil
	end
	if dropped then
		if by_weapon_aim == nil then
			by_weapon_aim = {}
			burst_aims[attacker.id] = by_weapon_aim
		end
		by_weapon_aim[weapon] = { target = target, point = target.position }
	end
	return fire(attacker, target, weapon, origin, late), target.id
end

-- What follows a shot of `weapon` when `fired` shots of its burst were out before it: how long until it may fire
-- again, the short gap within a burst or the full reload once the burst is out, and how many of the burst are then
-- out, which is back to none once it is over.
local function after_shot(weapon: types.Weapon, fired: number): (number, number)
	if fires_in_bursts(weapon) == false then
		return weapon.reload, 0
	end
	if fired + 1 >= (weapon.burst_count :: number) then
		return weapon.reload, 0
	end
	return weapon.burst_interval or DEFAULT_BURST_INTERVAL, fired + 1
end

-- Counts `remaining`, a reload, down by `delta`, unless it had already run out, and returns what is left. Nothing
-- is lost to the tick: a reload that runs out partway through one is left below zero by as much, which is how long
-- ago the weapon was ready, and the shot it then takes is that much into its flight already and makes the next
-- reload start that much sooner. A 0.267 second gap is 0.267 seconds on average, not a whole number of ticks.
local function count_down(remaining: number, delta: number): number
	if remaining > 0 then
		return remaining - delta
	end
	return remaining
end

-- Where each weapon's muzzle is on its owner's art, for a weapon on a turret piece of it: the turret's pivot and the
-- muzzle relative to that, from the art's origin (the ground under the collider's middle), and which weapon it is so
-- its aim can be read. `false` for a weapon whose art has no turret piece for it. Kept by weapon, which each def owns.
type Muzzle = { index: number, pivot: CFrame, point: Vector3, drop: CFrame }

-- Shots fired so far, by entity and weapon (see shots_of).
local shots: { [EntityId]: { [number]: number } } = {}

local function count_shot(entity_id: EntityId, index: number)
	local by_weapon = shots[entity_id]
	if by_weapon == nil then
		by_weapon = {}
		shots[entity_id] = by_weapon
	end
	by_weapon[index] = (by_weapon[index] or 0) + 1
end
local muzzles: { [types.Weapon]: Muzzle | false } = {}

local function muzzle_for(entity: Entity, weapon: types.Weapon): Muzzle?
	local cached = muzzles[weapon]
	if cached ~= nil then
		return if cached == false then nil else cached
	end
	local found: Muzzle | false = false
	local def = unit_defs.get(entity.def_name)
	local data = if art.has(entity.def_name) then art.get(entity.def_name) else nil
	if data ~= nil and def.weapons ~= nil then
		for index, candidate in def.weapons do
			if candidate ~= weapon then
				continue
			end
			for _, group in data.groups do
				if group.kind == "turret" and group.weapon == index and group.muzzle ~= nil then
					local pivot, point = group.pivot, group.muzzle
					found = {
						index = index,
						pivot = CFrame.new(pivot[1], pivot[2], pivot[3]),
						point = Vector3.new(point[1], point[2], point[3]),
						drop = CFrame.new(0, -unit_defs.collider_height(def) / 2, 0),
					}
					break
				end
			end
			break
		end
	end
	muzzles[weapon] = found
	return if found == false then nil else found
end

-- Where `weapon`'s shots come from: the tip of its barrel where its owner's art has a turret piece for it, turned
-- with the turret's aim; otherwise its own offset in `entity`'s frame, or the usual spot just above the middle of
-- anything with no offset of its own.
local function weapon_origin(entity: Entity, frame: CFrame, weapon: types.Weapon): Vector3
	local muzzle = muzzle_for(entity, weapon)
	if muzzle ~= nil then
		local aim = entity.weapon_aims[muzzle.index] or 0
		return (frame * muzzle.drop * muzzle.pivot * CFrame.Angles(0, aim, 0)):PointToWorldSpace(muzzle.point)
	end
	if weapon.offset ~= nil then
		return frame:PointToWorldSpace(weapon.offset)
	end
	return sight.muzzle_of(entity)
end

-- The index, within `weapons`, of the first one sharing weapon `index`'s `weapon_group`, or `index`
-- itself if it has none. Weapons in the same group reload as one: only their group's leader counts its
-- reload down, and every member reads and writes that one slot, so only whichever of them fires first
-- each cycle gets to.
local function group_leader(weapons: { types.Weapon }, index: number): number
	local group = weapons[index].weapon_group
	if group == nil then
		return index
	end
	for candidate, other in weapons do
		if other.weapon_group == group then
			return candidate
		end
	end
	return index
end

-- Whether `entity` has something it could shoot at this moment: an enemy within range of any of its
-- weapons that it has a clear line to, whether or not the weapon is reloading. It is what makes a unit on a
-- fight order stop walking.
local function has_target(entity: Entity): boolean
	local weapons = unit_defs.get(entity.def_name).weapons
	if weapons == nil then
		return false
	end
	local frame = CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0)
	for _, weapon in weapons do
		if any_target(entity, weapon_origin(entity, frame, weapon), weapon) then
			return true
		end
	end
	return false
end

-- Whether any of `entity`'s weapons could hit `target` from where it stands now: it can be turned on it, reaches it,
-- and has a clear shot at it, whether or not it is reloading. It is what an attack order walks on until it has, since
-- being in range of something behind a hill is not being able to shoot it.
local function can_shoot(entity: Entity, target: Entity): boolean
	local weapons = unit_defs.get(entity.def_name).weapons
	if weapons == nil then
		return false
	end
	local frame = CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0)
	local distance = geometry.distance_2d(entity.position, target.position)
	for _, weapon in weapons do
		if can_target(weapon, target) == false then
			continue
		end
		local origin = weapon_origin(entity, frame, weapon)
		if
			reaches(entity, weapon, origin, target.position, target.velocity, distance)
			and has_shot(entity, weapon, target, origin)
		then
			return true
		end
	end
	return false
end

-- The same for a bare `point` on the ground.
local function can_shoot_point(entity: Entity, point: Vector3): boolean
	local weapons = unit_defs.get(entity.def_name).weapons
	if weapons == nil then
		return false
	end
	local frame = CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0)
	local distance = geometry.distance_2d(entity.position, point)
	for _, weapon in weapons do
		if weapon.target_layer == "air" then
			continue
		end
		local origin = weapon_origin(entity, frame, weapon)
		if
			reaches(entity, weapon, origin, point, Vector3.zero, distance)
			and has_shot_at_point(entity, weapon, point, origin)
		then
			return true
		end
	end
	return false
end

-- What came of trying to fire a manual weapon: it "fired"; it is "waiting", for its reload or for energy, and
-- can be tried again; it is "blocked", by an enemy commander in the way, which is no better a moment later; or
-- the shooter is "unable" to, being dead, unfinished or without one.
export type ManualFireResult = "fired" | "waiting" | "blocked" | "unable"

-- Fires an entity's manual weapon toward `aim`. A rectangle sweeps out from the shooter along that
-- line for the weapon's whole range, and everything inside it except the shooter is destroyed
-- outright, with no wreck: it is disintegrated, whoever it belonged to, allies and your own included, as in
-- BAR. Only an enemy commander stops it: one in the way blocks the shot, which is BAR's answer to one commander
-- disintegrating another. Anything that even touches the rectangle counts, so each thing counts as a circle
-- its collider wide.
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
		-- it sweeps the ground, so an aircraft that is up in the air is over it; a reclaimable is not harmed by it,
		-- as it is by nothing
		if other.alive == false or other.id == shooter.id or other.kind == "reclaimable" or air.is_airborne(other) then
			continue
		end
		local reach = unit_defs.collider_radius(unit_defs.get(other.def_name))
		local offset = geometry.flatten(other.position - shooter.position)
		local along = offset:Dot(direction)
		local across = math.abs(offset:Dot(sideways))
		if along >= -reach and along <= weapon.range + reach and across <= weapon.radius + reach then
			-- an enemy commander in the way blocks the shot entirely: nothing is fired, nothing is spent
			if other.def_name == "commander" and alliances.are_allied(shooter.team, other.team) == false then
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

-- Runs every one of an entity's weapons, in order: each has its own reload, its own choice of target and
-- its own origin for the shot, except that weapons sharing a `weapon_group` share one reload between
-- them (`group_leader`) and so only ever fire one at a time. A weapon that is reloading is left alone,
-- and one that finds nothing in range simply waits, without holding up the others. Later weapons prefer
-- a target none of this entity's other weapons already claimed this tick, but take one that is claimed
-- over none at all.
--
-- A weapon on a turret decides what it means to shoot every tick, reloading or not, and turns toward it
-- (`turrets.turn`); once reloaded it fires only when it faces it, and otherwise waits ready. A pop-up's weapons
-- fire only while it is open (`turrets.advance`), and reload whatever it is doing.
local function tick_weapons(entity: Entity, weapons: { types.Weapon }, popup: types.Popup?, delta: number)
	local claimed: { EntityId } = {}
	local frame = CFrame.new(entity.position) * CFrame.Angles(0, entity.facing, 0)
	local open = popup == nil or turrets.advance(entity, popup, has_target(entity))

	for index, weapon in weapons do
		if entity.weapon_burst_remaining[index] == nil then
			entity.weapon_burst_remaining[index] = 0
		end
		if entity.weapon_reloads[index] == nil then
			entity.weapon_reloads[index] = 0
		end
		if entity.weapon_stockpiles[index] == nil then
			entity.weapon_stockpiles[index] = 0
		end
		if entity.weapon_stockpile_progress[index] == nil then
			entity.weapon_stockpile_progress[index] = 0
		end
		-- missiles go on being built whatever the weapon is doing, reloading after a launch included
		if weapon.stockpile ~= nil then
			entity.weapon_stockpiles[index], entity.weapon_stockpile_progress[index] = stockpiles.grow(
				entity.team,
				weapon.stockpile,
				entity.weapon_stockpiles[index],
				entity.weapon_stockpile_progress[index],
				delta
			)
		end

		local origin: Vector3? = nil
		local chosen: Choice? = nil
		local aligned = open
		local turret = weapon.turret
		if turret ~= nil then
			origin = weapon_origin(entity, frame, weapon)
			local choice = choose(entity, weapon, origin :: Vector3, claimed)
			chosen = choice
			local aim_point = if choice.point ~= nil
				then choice.point
				elseif choice.target ~= nil then choice.target.position
				else nil
			aligned = turrets.turn(entity, index, turret, origin :: Vector3, aim_point, delta) and open
		end

		local leader = group_leader(weapons, index)
		local remaining: number
		if leader ~= index then
			-- a grouped weapon has no reload of its own: it reads its group leader's, which the
			-- leader's own turn through this same loop already counted down, earlier this tick
			remaining = entity.weapon_reloads[leader]
		else
			remaining = count_down(entity.weapon_reloads[index], delta)
		end
		if remaining > 0 then
			if leader == index then
				entity.weapon_reloads[index] = remaining
			end
			continue
		end

		-- reloaded, but still turning to face its target or waiting to unfold: it waits ready, as with nothing to
		-- shoot, and does not save up the shots it could have taken
		if aligned == false then
			entity.weapon_reloads[leader] = 0
			continue
		end

		if origin == nil then
			origin = weapon_origin(entity, frame, weapon)
		end
		for _ = 1, MAX_SHOTS_PER_TICK do
			-- nothing to fire until a missile is ready, and with nothing to shoot it waits ready, and does not save
			-- up the shots it could have taken
			if weapon.stockpile ~= nil and entity.weapon_stockpiles[index] < 1 then
				remaining = 0
				break
			end
			local fired, at = shoot(
				entity,
				weapon,
				origin :: Vector3,
				claimed,
				entity.weapon_burst_remaining[index] > 0,
				-remaining,
				chosen
			)
			if fired == false then
				remaining = 0
				break
			end
			count_shot(entity.id, index)
			local wait: number
			wait, entity.weapon_burst_remaining[index] = after_shot(weapon, entity.weapon_burst_remaining[index])
			remaining += wait
			if weapon.stockpile ~= nil then
				entity.weapon_stockpiles[index] -= 1
				launched[entity.id] = true
			end
			if at ~= nil then
				table.insert(claimed, at)
			end
			if remaining > 0 then
				break
			end
		end
		-- whichever of a group actually fired (or found nothing to) sets the reload the rest of the
		-- group will read on their own turn through this loop, this tick or the next
		entity.weapon_reloads[leader] = remaining
	end
end

-- Burns every beam that is still up for one more tick: each deals its next slice to whatever is first on the line
-- from where its shooter is now to what it was fired at, and goes out once it has dealt its last, or has nothing
-- left to burn at. The line is checked with sight directly rather than through `los`, so that the whole cost of a
-- beam after its first tick is under the one `combat_beams` label.
local function tick_beams()
	local index = 1
	while index <= #beams do
		local beam = beams[index]
		local shooter = state.get(beam.shooter_id)
		local struck: Entity? = nil
		local burning = shooter ~= nil and shooter.alive
		if shooter ~= nil and burning then
			local frame = CFrame.new(shooter.position) * CFrame.Angles(0, shooter.facing, 0)
			local origin = weapon_origin(shooter, frame, beam.weapon)
			if beam.target_id ~= nil then
				local target = state.get(beam.target_id)
				if
					target == nil
					or target.alive == false
					or geometry.distance_2d(shooter.position, target.position) > beam.weapon.range
				then
					burning = false
				else
					struck = sight.first_hit(shooter, target, origin)
				end
			elseif beam.point ~= nil then
				struck = sight.first_hit_at(shooter, beam.point, origin)
			end
		end
		if struck ~= nil then
			hit(struck, beam.weapon, beam.slice)
		end
		beam.slices_left -= 1
		if burning == false or beam.slices_left <= 0 then
			beams[index] = beams[#beams]
			beams[#beams] = nil
		else
			index += 1
		end
	end
end

-- Rebuilds the target grid and clears the pick_target cache for the tick about to run - called
-- before orders.tick() (see init.server.luau), so a fight order's has_target check and this same
-- tick's actual shot both see one fresh grid and share one cached result per (attacker, weapon).
local function begin_tick()
	rebuild_target_grid()
	sight.invalidate()
	table.clear(pick_target_cache)
end

local function tick(delta: number)
	-- everything has moved since begin_tick, and a shot is judged against where things stand now
	sight.invalidate()
	local decay = RECENT_DAMAGE_DECAY ^ (delta * FRAMES_PER_SECOND)
	for id, damage in recent_damage do
		if damage * decay < 1e-3 or state.get(id) == nil then
			recent_damage[id] = nil
		else
			recent_damage[id] = damage * decay
		end
	end
	-- the beams already up burn on before anything fires this tick, so a beam fired now is not burned twice in it
	if #beams > 0 then
		local previous = profiler.current()
		profiler.mark "combat_beams"
		tick_beams()
		profiler.mark(previous)
	end
	for _, entity in state.all() do
		-- a wreck is what a unit leaves behind and keeps its def, but nothing of it fires, and nothing of a reclaimable
		if
			entity.alive == false
			or entity.state ~= "active"
			or entity.kind == "wreck"
			or entity.kind == "reclaimable"
		then
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
		local weapons = def.weapons
		if weapons ~= nil then
			tick_weapons(entity, weapons, def.popup, delta)
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
	burst_aims[entity_id] = nil
	starved_at[entity_id] = nil
	turrets.forget(entity_id)
	shots[entity_id] = nil
end

-- How many shots weapon `index` of `entity_id` has fired, for the client to play what firing looks like (a silo's
-- hatch swinging open) when it goes up.
local function shots_of(entity_id: EntityId, index: number): number
	local by_weapon = shots[entity_id]
	return if by_weapon ~= nil then by_weapon[index] or 0 else 0
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
	can_shoot = can_shoot,
	can_shoot_point = can_shoot_point,
	take_launch = take_launch,
	forget = forget,
	short_of_energy = short_of_energy,
	shots_of = shots_of,
})
