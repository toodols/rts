--!strict
-- What the scavengers' units decide to do. A new unit first gets clear of the others ("new"), and from then on wanders
-- ("wandering"), goes after anything of a player's it notices and has a way to ("hunting"), or goes looking for the
-- nearest such far off ("seeking"); its mode only ever changes through `enter`.
--
-- A unit on the ground only ever goes somewhere by a "straight run", a line across ground it can stand on all the way
-- (`pathfinder.has_straight_path`), which is nearly free, or when there is none by a route from `pathfinder`, of which
-- the scavengers have only their share each step (server/paths.luau). That holds for going after something it has
-- noticed as well: it goes to where it will shoot from, and never just straight at the thing, which up on a cliff would
-- run it into the cliff. A unit that is refused a route waits before it tries again.
--
-- A unit that gets nothing done for settings.FUTILE_SECONDS, stranded say on an island with no way across, is taken
-- away, and what it was worth is kept to be spent on something that can get across (`reroll_credit`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local teams = require(ReplicatedStorage.Shared.teams)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local passability = require(ReplicatedStorage.Shared.passability)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local walls = require(ReplicatedStorage.Shared.walls)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

local state = require(ServerScriptService.Server.state)
local deaths = require(ServerScriptService.Server.deaths)
local orders = require(ServerScriptService.Server.orders)
local shot_rules = require(ServerScriptService.Server.shot_rules)
local targeting = require(ServerScriptService.Server.targeting)
local movement = require(ServerScriptService.Server.movement)
local spatial = require(ServerScriptService.Server.spatial)
local rng = require(ServerScriptService.Server.rng)
local paths = require(ServerScriptService.Server.paths)

local settings = require(script.Parent.settings)
local progress = require(script.Parent.progress)
local roster = require(script.Parent.roster)
local snapshot = require(ServerScriptService.Server.snapshot)

type Entity = types.Entity
type EntityDef = types.EntityDef
type EntityId = types.EntityId
type Order = types.Order
type Weapon = types.Weapon

-- What a unit is doing: just made, and yet to get clear of the others; wandering; going after something it noticed; or
-- going looking for something far off.
type Mode = "new" | "wandering" | "hunting" | "seeking"

-- What a scavenger unit remembers between thoughts.
type Brain = {
	mode: Mode,
	next_think: number,
	last_position: Vector3,
	-- seconds it has been trying to go somewhere and getting nowhere
	stuck_for: number,
	-- it will not go hunting before this time, so that a chase it could not finish is not begun again at once
	ignore_until: number,
	-- it will not ask for another route before this time
	next_path_at: number,
	-- hunting, the target it has a route to and where that target was when the route was made; and hunting or seeking,
	-- until when the route is left alone
	route_target: EntityId?,
	route_anchor: Vector3?,
	route_until: number,
	-- a target it found no way to, and until when it is not tried for again
	avoid_target: EntityId?,
	avoid_until: number,
	-- The last time it got anything done (`settings.FUTILE_SECONDS`), when it next looks at how near it is to the
	-- nearest thing of a player's, and the nearest it has been to that thing.
	useful_at: number,
	next_futile_check: number,
	closest: number,
	closest_target: EntityId?,
}

-- How often a unit makes up its mind, and how far it has to get in that time, while it has somewhere to be, to count as
-- getting anywhere. Failing for STUCK_LIMIT seconds it gives up on where it was going.
local THINK_INTERVAL = 1
local STUCK_DISTANCE = 1
local STUCK_LIMIT = 3
local STUCK_IGNORE_TIME = 8
-- Tries at a long wander, and then as many at a short one, for a unit that is on ground with little room.
local ROAM_ATTEMPTS = 8
local ROAM_SHORT_MIN = 10
-- A new unit heads off away from its beacon by up to this far either side of straight out, and leaves the hunting alone
-- for this long, so that a wave does not stay bunched on the spot it appeared.
local SCATTER_FAN = math.pi / 3
local SCATTER_TIME = 5
-- A hunter walks to a spot of its own on a ring round its target, spread over this much of the ring on the side it
-- comes from. The spot comes from its id, so it stays the same from one moment to the next, and different ids fall in
-- different places.
local SLOT_SPREAD = math.pi
local SLOT_ID_STRIDE = 0.618034
-- Routes. The scavengers together have one a step (server/paths.luau), and none may search more than 2500 cells, which
-- is about twenty milliseconds at the worst. A route the
-- search is cut off from still leads part of the way, and a unit that is seeking asks again from where it gets to. A
-- route is trusted for ROUTE_HOLD seconds, which is long enough to walk a good way round, and is redone before that only
-- if its target has moved further than ROUTE_TARGET_DRIFT from where it was. A unit waits ROUTE_COOLDOWN seconds between
-- one route and the next, PATH_RETRY_DELAY if it was refused or let down, and gives up on a target it found no way to
-- for AVOID_TIME.
local ASKER: paths.Asker = table.freeze({ name = "scavengers", share = 1, max_expansions = 2500 })
local ROUTE_HOLD = 30
local ROUTE_COOLDOWN = 5
local ROUTE_TARGET_DRIFT = 40
local PATH_RETRY_DELAY = 10
local AVOID_TIME = 30
-- Seeking. A unit that is looking for something far off goes to a staging spot this share of the detection range from
-- it, close enough that hunting takes over from there. A route that ends less than SEEK_MIN_PROGRESS nearer to it than
-- the unit already is has got nowhere, and counts as no way there.
local SEEK_STAGE_SHARE = 0.8
local SEEK_MIN_PROGRESS = 30
-- How many places on the map a stranded unit tries for a route to.
local ROAM_ROUTE_TRIES = 6
-- How often a unit looks at whether it is getting anywhere (`settings.FUTILE_SECONDS`).
local FUTILE_CHECK_INTERVAL = 5
-- Close in to a little inside the nominal range, as `orders` does when it closes on a target, so that "can it get within
-- range" is asked of the spot it would actually stop at.
local RANGE_MARGIN = order_kinds.RANGE_MARGIN

local brains: { [EntityId]: Brain } = {}
-- What the units that got nothing done were worth, in difficulty, still to be spent on ones that can get across.
local credit_left = 0
-- When the scavengers' manual-fire weapons next look for something to fire at (`aim_manual_weapons`).
local next_aim_at = 0

local function is_scavenger(entity: Entity): boolean
	return entity.team == teams.SCAVENGER
end

-- How far a unit reaches to fight: its longest weapon, or, for a carrier with none, how far out its drones go.
local function reach_of(def: EntityDef): number?
	local reach = unit_defs.attack_range(def)
	if reach == nil and def.carrier ~= nil then
		return def.carrier.engage_range
	end
	return reach
end

-- How many units the scavengers have out, drones apart.
local function count(): number
	local found = 0
	for _, other in state.all() do
		if
			other.alive
			and other.kind == "unit"
			and other.state == "active"
			and is_scavenger(other)
			and unit_defs.is_drone(other.def) == false
		then
			found += 1
		end
	end
	return found
end

-- The nearest thing of a player's within `within` of `unit` that `weapon` can be turned on and that it has noticed, the
-- one with the least id of any as near (spatial.nearest). `avoid` is one that is not to be considered, because there
-- was no way to it.
local function nearest_target(unit: Entity, weapon: Weapon, avoid: EntityId?, within: number): Entity?
	return spatial.nearest(unit.position, within, function(other: Entity, distance: number): boolean
		return other.id ~= avoid
			and targeting.is_enemy(unit, other)
			and shot_rules.can_target(weapon, other)
			and targeting.spots(other, distance)
	end)
end

-- The spot of its own that a hunter goes to round its target, at shooting range on the side it is coming from, or nil
-- if that is off the map. It comes from the unit's id, so it stays the same from one moment to the next and different
-- units fall in different places.
local function hunt_slot(unit: Entity, def: EntityDef, target: Entity): Vector3?
	local reach = reach_of(def)
	if reach == nil then
		return nil
	end
	local from_target = geometry.flatten(unit.position - target.position)
	local approach = if from_target.Magnitude > 1e-3 then math.atan2(from_target.Z, from_target.X) else 0
	local angle = approach + ((unit.id * SLOT_ID_STRIDE) % 1 - 0.5) * SLOT_SPREAD
	local x = target.position.X + math.cos(angle) * reach * RANGE_MARGIN
	local z = target.position.Z + math.sin(angle) * reach * RANGE_MARGIN
	if heightmap.in_bounds(x, z) == false then
		return nil
	end
	return heightmap.ground_position(x, z)
end

local function is_same_order(current: Order?, wanted: Order): boolean
	if current == nil or current.kind ~= wanted.kind or current.target_id ~= wanted.target_id then
		return false
	end
	if wanted.position == nil then
		return true
	end
	return current.position ~= nil and geometry.distance_2d(current.position, wanted.position) < 2
end

-- The way for `unit` to `goal`: a straight run if it has one, and otherwise a route, if the scavengers have any left
-- this step. nil means none was made, and the unit goes on with what it had and asks again at its next thought.
local function way_to(unit: Entity, def: EntityDef, goal: Vector3): paths.Route?
	return paths.route(ASKER, nil, def, unit.position, goal, "move")
end

-- Whether something of `def` can stand at (x, z): the water is the right depth, the ground is not too steep, and no
-- building stands there.
local function is_standable(def: EntityDef, x: number, z: number): boolean
	if heightmap.in_bounds(x, z) == false then
		return false
	end
	local depth = heightmap.water_depth(x, z)
	return unit_defs.tolerates_water(def, depth, depth)
		and passability.passable_at(def.footing.class, x, z)
		and walls.blocked_at(x, z) == false
end

-- Puts `unit` in `mode`, the one way a mode changes: what it had of hunting goes unless it hunts, and with
-- `stop` it drops whatever it was doing.
local function enter(unit: Entity, brain: Brain, mode: Mode, stop: boolean)
	brain.mode = mode
	if mode ~= "hunting" then
		brain.route_target = nil
	end
	if stop then
		orders.issue(unit, {}, false, false)
	end
end

-- Goes after `target`: to its own spot at shooting range on the side it is coming from, and then an attack. Hunters that
-- all made for the target itself would stop in a clump at the front and leave the ones behind unable to get into range.
-- It goes there straight if it can walk the whole line, and otherwise by a route, so that it goes round a cliff or a
-- lake rather than into it. From its spot, the attack order walks it on if the ground is in the way of its shot, and
-- finds its way doing it, as any attack does.
--
-- It counts a route as good if it gets all the way, or, when there is water or a cliff between, as far as a place within
-- reach of the target, since it can shoot across. Otherwise it gives the target up for a while. A carrier with nothing
-- of its own to shoot goes to its spot and stays there, and its drones do the fighting.
local function hunt(unit: Entity, brain: Brain, def: EntityDef, target: Entity)
	local now = progress.now()
	local anchor = brain.route_anchor
	if
		brain.route_target == target.id
		and anchor ~= nil
		and unit.orders[1] ~= nil
		and now < brain.route_until
		and geometry.distance_2d(anchor, target.position) <= ROUTE_TARGET_DRIFT
	then
		brain.useful_at = now
		return
	end
	if now < brain.next_path_at then
		return
	end

	local goal = hunt_slot(unit, def, target) or target.position
	local route = way_to(unit, def, goal)
	if route == nil then
		return
	end
	if route.searched then
		brain.next_path_at = now + ROUTE_COOLDOWN
		local last = route.orders[#route.orders]
		local reach = reach_of(def) or 0
		local near_enough = route.complete
			or (last ~= nil and geometry.distance_2d(last.position or unit.position, target.position) <= reach)
		if near_enough == false then
			brain.avoid_target = target.id
			brain.avoid_until = now + AVOID_TIME
			brain.next_path_at = now + PATH_RETRY_DELAY
			enter(unit, brain, "wandering", true)
			return
		end
	end

	local chain = table.clone(route.orders)
	if def.weapons ~= nil then
		table.insert(chain, { kind = "attack", target_id = target.id })
	end
	orders.issue(unit, chain, false, false)
	-- it has a way to something it can shoot, which is getting something done
	brain.useful_at = now
	brain.route_target = target.id
	brain.route_anchor = target.position
	brain.route_until = now + ROUTE_HOLD
end

-- For a unit with nowhere it has a straight run to: a route to somewhere else on the map it could stand, if there is
-- one, so that a unit stranded behind a lake or a ridge is not stranded for good.
local function roam_by_route(unit: Entity, brain: Brain, def: EntityDef)
	if progress.now() < brain.next_path_at then
		return
	end
	local extent_x, extent_z = heightmap.half_extents()
	for _ = 1, ROAM_ROUTE_TRIES do
		local x = rng.stream("scavengers"):NextNumber(-extent_x, extent_x)
		local z = rng.stream("scavengers"):NextNumber(-extent_z, extent_z)
		if is_standable(def, x, z) then
			local route = way_to(unit, def, heightmap.ground_position(x, z))
			if route == nil then
				return
			end
			brain.next_path_at = progress.now() + PATH_RETRY_DELAY
			if route.complete and #route.orders > 0 then
				orders.issue(unit, route.orders, false, false)
			end
			return
		end
	end
end

-- Goes looking for the nearest thing of a player's, wherever it is, and returns whether it is on its way. There is a
-- straight run to a staging spot near it, or there is a route, or the unit gives that one up for a while. Once it is
-- close enough to notice it, hunting takes over and this is not asked.
local function seek(unit: Entity, brain: Brain, def: EntityDef, weapon: Weapon): boolean
	local now = progress.now()
	-- only some units go looking, and which is fixed by the unit's id
	if (unit.id * SLOT_ID_STRIDE) % 1 >= settings.SEEKER_SHARE then
		return false
	end
	-- already on its way, by a route it was given not long ago
	if brain.mode == "seeking" and unit.orders[1] ~= nil and now < brain.route_until then
		return true
	end
	if now < brain.next_path_at then
		return false
	end

	local avoid = if now < brain.avoid_until then brain.avoid_target else nil
	local target = nearest_target(unit, weapon, avoid, math.huge)
	if target == nil then
		return false
	end
	local away = geometry.flatten(unit.position - target.position)
	local distance = away.Magnitude
	local stage_distance = settings.DETECTION_RANGE * SEEK_STAGE_SHARE
	if distance <= stage_distance or distance < 1e-3 then
		return false
	end
	local x = target.position.X + away.X / distance * stage_distance
	local z = target.position.Z + away.Z / distance * stage_distance
	if heightmap.in_bounds(x, z) == false then
		return false
	end
	local stage = heightmap.ground_position(x, z)

	-- a straight run is nearly free, and needs no route
	local route = way_to(unit, def, stage)
	if route == nil then
		return false
	end
	brain.next_path_at = now + ROUTE_COOLDOWN
	local last = route.orders[#route.orders]
	local end_position = if last ~= nil then last.position else nil
	local got_somewhere = route.searched == false
		or (end_position ~= nil and distance - geometry.distance_2d(end_position, target.position) >= SEEK_MIN_PROGRESS)
	if got_somewhere == false then
		if brain.mode == "seeking" then
			enter(unit, brain, "wandering", false)
		end
		brain.avoid_target = target.id
		brain.avoid_until = now + AVOID_TIME
		brain.next_path_at = now + PATH_RETRY_DELAY
		return false
	end
	orders.issue(unit, route.orders, false, false)
	enter(unit, brain, "seeking", false)
	brain.route_until = now + ROUTE_HOLD
	return true
end

-- Somewhere for `unit` to wander to: a random spot a fair way off that it has a straight run at.
local function pick_waypoint(unit: Entity, def: EntityDef): Vector3?
	for attempt = 1, ROAM_ATTEMPTS * 2 do
		-- the long wanders first, then shorter ones for a unit with little ground to go on
		local distance = if attempt <= ROAM_ATTEMPTS
			then rng.stream("scavengers"):NextNumber(settings.ROAM_MIN, settings.ROAM_MAX)
			else rng.stream("scavengers"):NextNumber(ROAM_SHORT_MIN, settings.ROAM_MIN)
		local angle = rng.stream("scavengers"):NextNumber(0, math.pi * 2)
		local x = unit.position.X + math.cos(angle) * distance
		local z = unit.position.Z + math.sin(angle) * distance
		if heightmap.in_bounds(x, z) then
			local point = heightmap.ground_position(x, z)
			if pathfinder.has_straight_path(def, unit.position, point) then
				return point
			end
		end
	end
	return nil
end

-- Somewhere far off in the direction `outward`, give or take, for a unit that has just appeared and has to get clear of
-- the others.
local function pick_scatter_point(unit: Entity, def: EntityDef, outward: Vector3): Vector3?
	for _ = 1, ROAM_ATTEMPTS do
		local turn = rng.stream("scavengers"):NextNumber(-SCATTER_FAN, SCATTER_FAN)
		local cosine = math.cos(turn)
		local sine = math.sin(turn)
		local distance = rng.stream("scavengers"):NextNumber(settings.ROAM_MIN, settings.ROAM_MAX)
		local x = unit.position.X + (outward.X * cosine - outward.Z * sine) * distance
		local z = unit.position.Z + (outward.X * sine + outward.Z * cosine) * distance
		if heightmap.in_bounds(x, z) then
			local point = heightmap.ground_position(x, z)
			if pathfinder.has_straight_path(def, unit.position, point) then
				return point
			end
		end
	end
	return nil
end

local function brain_for(unit: Entity): Brain
	local brain = brains[unit.id]
	if brain == nil then
		local now = progress.now()
		brain = {
			mode = "new",
			-- staggered, so a whole wave does not do all its thinking on the same tick
			next_think = now + rng.stream("scavengers"):NextNumber(0, THINK_INTERVAL),
			last_position = unit.position,
			stuck_for = 0,
			ignore_until = 0,
			next_path_at = 0,
			route_target = nil,
			route_anchor = nil,
			route_until = 0,
			avoid_target = nil,
			avoid_until = 0,
			useful_at = now,
			next_futile_check = now + FUTILE_CHECK_INTERVAL,
			closest = math.huge,
			closest_target = nil,
		}
		brains[unit.id] = brain
	end
	return brain :: Brain
end

-- Whether `unit` has got nothing done for `settings.FUTILE_SECONDS`: not gone after anything it could reach (see
-- `hunt`), and not got any nearer the nearest thing of a player's than it had been. Every so often it looks at how near
-- that is; a new nearest thing starts the reckoning again from where it stands, and with nothing of a player's it could
-- turn on there is nothing to get done, so it is not held against it. Aircraft go wherever they like, and their boss is
-- never taken away.
local function is_futile(unit: Entity, brain: Brain, def: EntityDef): boolean
	if unit_defs.is_air(def) or unit_defs.is_boss(def) then
		return false
	end
	local now = progress.now()
	if now >= brain.next_futile_check then
		brain.next_futile_check = now + FUTILE_CHECK_INTERVAL
		local weapon = roster.main_weapon(def)
		local target = if weapon ~= nil then nearest_target(unit, weapon, nil, math.huge) else nil
		if target == nil then
			brain.useful_at = now
		else
			local distance = geometry.distance_2d(unit.position, target.position)
			if target.id ~= brain.closest_target then
				brain.closest_target = target.id
				brain.closest = distance
			elseif distance <= brain.closest - settings.FUTILE_PROGRESS then
				brain.closest = distance
				brain.useful_at = now
			end
		end
	end
	return now - brain.useful_at >= settings.FUTILE_SECONDS
end

-- One unit making up its mind: hunt what it can reach, otherwise keep wandering.
local function think(unit: Entity, brain: Brain)
	local def = unit.def
	local now = progress.now()
	brain.next_think = now + THINK_INTERVAL

	-- stranded, say on an island with no way across: it is taken away, with no wreck, and what it was worth goes to
	-- making something that can get across
	if is_futile(unit, brain, def) then
		credit_left += roster.difficulty_of(unit.def_name)
		brains[unit.id] = nil
		deaths.destroy(unit, "removed")
		return
	end

	-- whether it was trying to go somewhere, and got nowhere
	local moved = geometry.distance_2d(unit.position, brain.last_position)
	brain.last_position = unit.position
	if movement.had_goal(unit.id) and moved < STUCK_DISTANCE then
		brain.stuck_for += THINK_INTERVAL
	else
		brain.stuck_for = 0
	end
	if brain.stuck_for >= STUCK_LIMIT then
		-- a lake or the edge of the map in the way: give up on it and wander somewhere else for a while
		brain.stuck_for = 0
		brain.ignore_until = now + STUCK_IGNORE_TIME
		enter(unit, brain, "wandering", true)
	end

	-- The first thing a new unit does is head away from the others, so a wave does not stand about in a clump at its
	-- beacon, or all set off after the same thing from the same place.
	if brain.mode == "new" then
		enter(unit, brain, "wandering", false)
		local outward = Vector3.new(math.sin(unit.facing), 0, math.cos(unit.facing))
		local point = pick_scatter_point(unit, def, outward)
		if point ~= nil then
			brain.ignore_until = now + SCATTER_TIME
			orders.push_move(unit, point, false)
			return
		end
	end

	local weapon = roster.main_weapon(def)
	if weapon ~= nil and now >= brain.ignore_until then
		local avoid = if now < brain.avoid_until then brain.avoid_target else nil
		local target = if reach_of(def) ~= nil
			then nearest_target(unit, weapon, avoid, settings.DETECTION_RANGE)
			else nil
		if target ~= nil then
			if brain.mode ~= "hunting" then
				enter(unit, brain, "hunting", false)
			end
			-- an aircraft flies over whatever is in the way, so it needs no route; a bomber's attack order is what makes
			-- it fly its bombing runs
			if unit_defs.is_air(def) then
				local wanted: Order = { kind = "attack", target_id = target.id }
				if is_same_order(unit.orders[1], wanted) == false then
					orders.issue(unit, { wanted }, false, false)
				end
				return
			end
			hunt(unit, brain, def, target)
			return
		end
		-- whatever it was chasing is gone, or out of reach, so the chase is over
		if brain.mode == "hunting" then
			enter(unit, brain, "wandering", true)
		end
		-- nothing near enough to notice: go looking for something further off
		if seek(unit, brain, def, weapon) then
			return
		end
	end

	if unit.orders[1] == nil then
		local point = pick_waypoint(unit, def)
		if point ~= nil then
			orders.push_move(unit, point, false)
		else
			roam_by_route(unit, brain, def)
		end
	end
end

-- A manual-fire weapon, a nuclear silo's, fires only when it is told what at (`Weapon.manual_fire`), so the scavengers
-- tell theirs: one with a missile ready and nothing to do is ordered to launch at the costliest thing of a player's
-- that it can reach (roster.luau's `difficulty_of`). Every THINK_INTERVAL seconds, like their units' thinking.
local function aim_manual_weapons()
	local now = progress.now()
	if now < next_aim_at then
		return
	end
	next_aim_at = now + THINK_INTERVAL
	for _, shooter in state.all() do
		if is_scavenger(shooter) == false or shooter.alive == false or shooter.state ~= "active" then
			continue
		end
		if #shooter.orders > 0 then
			continue
		end
		local def = shooter.def
		if def.weapons == nil then
			continue
		end
		for index, weapon in def.weapons do
			if weapon.manual_fire ~= true then
				continue
			end
			if weapon.stockpile ~= nil and shooter.weapon_stockpiles[index].held < 1 then
				continue
			end
			-- the dearest in reach, the one with the least id of any as dear
			local best: Entity? = nil
			local best_worth = -math.huge
			spatial.each_present(shooter.position, weapon.range, function(other: Entity, distance: number): boolean?
				if
					targeting.is_enemy(shooter, other)
					and shot_rules.can_target(weapon, other)
					and targeting.spots(other, distance)
				then
					local worth = roster.difficulty_of(other.def_name)
					if worth > best_worth or (worth == best_worth and best ~= nil and other.id < best.id) then
						best = other
						best_worth = worth
					end
				end
				return nil
			end)
			if best ~= nil then
				orders.issue(
					shooter,
					{ { kind = "attack", position = nil, target_id = best.id, launch = true } },
					false,
					false
				)
				break
			end
		end
	end
end

-- Every unit of theirs makes up its mind when its time comes, and their manual-fire weapons are aimed. A beacon that
-- stops making things does not stop what it already made.
local function run()
	local now = progress.now()
	for _, unit in state.all() do
		if is_scavenger(unit) == false or unit.alive == false or spatial.is_mobile(unit) == false then
			continue
		end
		-- a drone is its carrier's to send out, and to call back
		if unit_defs.is_drone(unit.def) then
			continue
		end
		local brain = brain_for(unit)
		if now >= brain.next_think then
			think(unit, brain)
		end
	end
	aim_manual_weapons()
end

-- What the units that got nothing done were worth that is still to be spent on ones that can get across.
local function reroll_credit(): number
	return credit_left
end

-- `amount` of that credit spent.
local function spend_credit(amount: number)
	credit_left -= amount
end

-- Forgets the unit `id`, which is gone.
local function forget(id: EntityId)
	brains[id] = nil
end

-- A new game on a new map: nothing of the last is remembered.
local function reset()
	table.clear(brains)
	credit_left = 0
	next_aim_at = 0
end

snapshot.keep("scavenger_units", function()
	return { brains = brains, credit_left = credit_left, next_aim_at = next_aim_at }
end, function(saved)
	brains = saved.brains
	credit_left = saved.credit_left
	next_aim_at = saved.next_aim_at
end)

return table.freeze({
	count = count,
	run = run,
	reroll_credit = reroll_credit,
	spend_credit = spend_credit,
	forget = forget,
	reset = reset,
})
