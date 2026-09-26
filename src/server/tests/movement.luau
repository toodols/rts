--!strict
-- Tests of how units find their way and walk it: routes up onto the plateau, crowds, orders that walk to something,
-- units coming out of labs, and buildings as walls.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local world_scale = require(ReplicatedStorage.Shared.world_scale)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local geometry = require(ReplicatedStorage.Shared.geometry)
local walls = require(ReplicatedStorage.Shared.walls)

local state = require(ServerScriptService.Server.state)
local orders = require(ServerScriptService.Server.orders)
local movement = require(ServerScriptService.Server.movement)
local targeting = require(ServerScriptService.Server.targeting)
local sight = require(ServerScriptService.Server.sight)
local production = require(ServerScriptService.Server.production)
local placement = require(ServerScriptService.Server.placement)
local deaths = require(ServerScriptService.Server.deaths)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local ENEMY = harness.ENEMY
local NOCOST = harness.NOCOST
local advance = harness.advance
local now = harness.now
local round = harness.round
local spawn = harness.spawn
local spawn_resting = harness.spawn_resting
local unkillable = harness.unkillable
local damage_to = harness.damage_to
local clear_world = harness.clear_world
local with_switch = harness.with_switch

type Entity = types.Entity
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- The most a unit on its own may spend pushing and getting nowhere on its way.
local MOST_STUCK_ALONE = 2
-- The most any one of a crowd may.
local MOST_STUCK_IN_CROWD = 10

-- A lab of `lab_name` of OWN's, finished, where it rests at the middle of the map, turned to `facing`.
-- The newest of `def_name` team `team` has, finished or not: the last one its lab started.
local function newest_of(team: types.TeamId, def_name: string): Entity?
	local newest: Entity? = nil
	for _, entity in state.all() do
		if entity.alive and entity.team == team and entity.def_name == def_name then
			if newest == nil or entity.id > newest.id then
				newest = entity
			end
		end
	end
	return newest
end

local function put_lab(lab_name: string, facing: number): Entity
	local lab_def = unit_defs.get(lab_name)
	local y = surface.height(lab_def, 0, 0) + unit_defs.collider_height(lab_def) / 2
	local lab = unkillable(state.create_entity(lab_name, OWN, Vector3.new(0, y, 0), facing, "active"))
	return lab
end

-- A move given the way a player's is (`pathfinder.route`, as `commands` does it): a Grunt, or `args.unit`, sent from
-- the low ground at the foot of the plateau up onto it, and then across open ground on the plateau. For each: how
-- many waypoints it was given, whether it needed a search, whether it got there, how long it took, and how long it
-- spent trying to go somewhere and getting nowhere. Then a crowd, `args.crowd` (12) of them, sent up together. Every
-- one should get there, none stuck long.
local function move_route(args: Args): Findings
	local def_name = args.unit or "grunt"
	local def = unit_defs.get(def_name)
	local walker = spawn(def_name, OWN, 190, -120)
	advance(tick_rate.TICK_DELTA)

	local function go(to_x: number, to_z: number): Findings
		local destination = heightmap.ground_position(to_x, to_z)
		local route, searched = pathfinder.route(def, walker.position, destination, 8000)
		orders.issue(walker, route, false, false)
		local started = now()
		local watch, stuck = harness.stuck_watch(walker)
		local arrived = harness.until_idle(walker, args.seconds or 60, watch)
		local offset = destination - walker.position
		return {
			waypoints = #route,
			searched = searched,
			arrived = arrived,
			seconds = round(now() - started, 2),
			seconds_stuck = round(stuck(), 2),
			left_to_go = round(Vector3.new(offset.X, 0, offset.Z).Magnitude, 1),
		}
	end
	local findings: Findings = {
		up_onto_plateau = go(140, -120),
		across_plateau = go(140, -80),
	}
	clear_world()

	-- a crowd sent up together, each to its own spot, the way a player's move spreads a group
	local crowd: { Entity } = {}
	for index = 1, args.crowd or 12 do
		table.insert(crowd, spawn(def_name, OWN, 186 + (index % 4) * 3, -126 + (index // 4) * 3))
	end
	advance(tick_rate.TICK_DELTA)
	local searches = 0
	for index, member in crowd do
		local spot = heightmap.ground_position(136 + (index % 4) * 3, -124 + (index // 4) * 3)
		local route, searched = pathfinder.route(def, member.position, spot, 8000)
		if searched then
			searches += 1
		end
		orders.issue(member, route, false, false)
	end
	local watches: { () -> () } = {}
	local stuck_times: { () -> number } = {}
	for _, member in crowd do
		local watch, stuck = harness.stuck_watch(member)
		table.insert(watches, watch)
		table.insert(stuck_times, stuck)
	end
	local started = now()
	local deadline = now() + (args.seconds or 60)
	local arrived = 0
	while now() < deadline do
		advance(tick_rate.TICK_DELTA, function()
			for _, watch in watches do
				watch()
			end
		end)
		arrived = 0
		for _, member in crowd do
			if #member.orders == 0 then
				arrived += 1
			end
		end
		if arrived == #crowd then
			break
		end
	end
	local worst_stuck = 0
	for _, stuck in stuck_times do
		worst_stuck = math.max(worst_stuck, stuck())
	end
	findings.crowd = {
		size = #crowd,
		searched = searches,
		arrived = arrived,
		seconds = round(now() - started, 2),
		worst_seconds_stuck = round(worst_stuck, 2),
	}
	findings.pass = findings.up_onto_plateau.arrived
		and findings.up_onto_plateau.seconds_stuck <= MOST_STUCK_ALONE
		and findings.across_plateau.arrived
		and findings.across_plateau.seconds_stuck <= MOST_STUCK_ALONE
		and arrived == #crowd
		and worst_stuck <= MOST_STUCK_IN_CROWD
	return findings
end

-- Orders that walk to something, given the way a player's are, with their way laid ahead of them as waypoints
-- (`harness.player_route`): a Grunt, or `args.unit`, on the low ground at the foot of the plateau is told to attack a
-- solar collector up on it, and then, from the same spot, to fight its way to a point on the plateau past another
-- collector where the first one stood, which it can see on the way. For each: whether it got up there, how long it
-- spent trying to go somewhere and getting nowhere, how much it hurt what it was after, and, for the fight, whether it
-- finished. It should get up there and hurt the first, and finish the fight without getting stuck on the way; what it
-- makes of the second, which it passes by out of its reach unless `args.passed_x` and `args.passed_z` put it nearer,
-- is reported.
local function walk_orders(args: Args): Findings
	local def_name = args.unit or "grunt"

	local target = unkillable(spawn("solar_collector", ENEMY, 140, -120))
	local attacker = spawn(def_name, OWN, 190, -120)
	advance(tick_rate.TICK_DELTA)
	local attack_steps = harness.player_route(attacker, { kind = "attack", target_id = target.id })
	orders.issue(attacker, attack_steps, false, false)
	local attack_watch, attack_stuck = harness.stuck_watch(attacker)
	harness.until_idle(attacker, args.seconds or 40, attack_watch)
	local attack = {
		waypoints_ahead = #attack_steps - 1,
		seconds_stuck = round(attack_stuck(), 2),
		height_below_target = round(target.position.Y - attacker.position.Y, 1),
		damage_to_target = round(damage_to(target), 0),
	}
	clear_world()

	local passed = unkillable(spawn("solar_collector", ENEMY, args.passed_x or 140, args.passed_z or -120))
	local marcher = spawn(def_name, OWN, 190, -120)
	advance(tick_rate.TICK_DELTA)
	local destination = heightmap.ground_position(130, -80)
	local fight_steps, fight_sent = harness.player_route(marcher, { kind = "fight", position = destination })
	orders.issue(marcher, fight_steps, false, false)
	local closest = math.huge
	local stops = 0
	local shot_seconds = 0
	local closest_verdict = ""
	local closest_rise = 0
	local fight_watch, fight_stuck = harness.stuck_watch(marcher)
	local finished = harness.until_idle(marcher, args.seconds or 60, function()
		fight_watch()
		if movement.had_goal(marcher.id) == false and #marcher.orders > 0 then
			stops += 1
		end
		local gap = passed.position - marcher.position
		local flat = Vector3.new(gap.X, 0, gap.Z).Magnitude
		if flat < closest then
			closest_verdict = sight.verdict(marcher, passed, unit_defs.muzzle_of(marcher.def, marcher.position))
			closest_rise = gap.Y
		end
		closest = math.min(closest, flat)
		if targeting.can_shoot(marcher, passed) then
			shot_seconds += tick_rate.TICK_DELTA
		end
	end)
	local offset = destination - marcher.position
	local fight = {
		waypoints_sent = fight_sent,
		waypoints_taken = #fight_steps - 1,
		finished = finished,
		seconds_stuck = round(fight_stuck(), 2),
		left_to_go = round(Vector3.new(offset.X, 0, offset.Z).Magnitude, 1),
		damage_on_the_way = round(damage_to(passed), 0),
		closest_to_it = round(closest, 1),
		range = round(unit_defs.attack_range(unit_defs.get(def_name)) or 0, 1),
		seconds_stopped = round(stops * tick_rate.TICK_DELTA, 2),
		seconds_it_had_a_shot = round(shot_seconds, 2),
		verdict_when_closest = closest_verdict,
		its_height_above_when_closest = round(closest_rise, 1),
	}
	return {
		attack = attack,
		fight = fight,
		pass = attack.damage_to_target > 0
			and attack.seconds_stuck <= MOST_STUCK_ALONE
			and fight.finished
			and fight.seconds_stuck <= MOST_STUCK_ALONE,
	}
end

-- A Bot Lab, or `args.lab`, turned each quarter in turn, making two Grunts, or `args.unit`s, at no cost. For each: where
-- the blueprint went down, in studs to the lab's right and out through its doorway, and which way it faced; which way
-- the first unit drove while it was getting out and how long that took, with a move back through the lab given to it
-- half way out, the way a player's would be; how deep it ever was in the lab once it was out, as that move takes it
-- round; and how long after the first unit was out the second blueprint went down. Each should drive straight out of
-- the doorway keeping its order, get no deeper into the lab than a unit the lab did not make, and the lab should start
-- the second.
local function lab_exit(args: Args): Findings
	local lab_name = args.lab or "bot_lab"
	local unit_name = args.unit or "grunt"
	local findings: Findings = {}
	local pass = true

	-- what a unit costs is beside the point: it is finished the moment the lab starts it
	with_switch(NOCOST, true, function()
		for quarter = 0, 3 do
			local facing = quarter * math.pi / 2
			local lab = put_lab(lab_name, facing)
			local out = Vector3.new(math.sin(facing), 0, math.cos(facing))
			local right = Vector3.new(-out.Z, 0, out.X)
			local function local_of(position: Vector3): { number }
				local offset = geometry.flatten(position - lab.position)
				return { round(offset:Dot(right), 2), round(offset:Dot(out), 2) }
			end
			local function penetration(unit: Entity): number
				local a = placement.half_extents_for(unit)
				local b = placement.half_extents_for(lab)
				local dx = a.X + b.X - math.abs(unit.position.X - lab.position.X)
				local dz = a.Y + b.Y - math.abs(unit.position.Z - lab.position.Z)
				return math.max(0, math.min(dx, dz))
			end

			local before = newest_of(lab.team, unit_name)
			production.enqueue(lab, unit_name)
			production.enqueue(lab, unit_name)
			local report: Findings = {}

			-- the first blueprint
			local first: Entity? = nil
			local second_placed: number? = nil
			local function watch()
				local newest = newest_of(lab.team, unit_name)
				local id = if newest ~= nil and newest ~= before then newest.id else nil
				if id == nil then
					return
				end
				if first == nil then
					first = state.get(id)
					report.blueprint_at = local_of((first :: Entity).position)
				elseif second_placed == nil and id ~= (first :: Entity).id then
					second_placed = now()
				end
			end
			advance(1, watch)
			local unit = first :: Entity
			report.blueprint_facing_out = round(math.cos(unit.facing - math.atan2(out.X, out.Z)), 3)

			local deadline = now() + 60
			while unit.state == "blueprint" and now() < deadline do
				advance(tick_rate.TICK_DELTA, watch)
			end
			-- the tick after it is finished, the lab sends it out
			advance(tick_rate.TICK_DELTA)
			report.exiting = movement.exiting_from(unit.id) == lab.id
			local began = now()
			local start = unit.position
			local told = false
			local behind = lab.position - out * 40
			while movement.exiting_from(unit.id) ~= nil and now() < began + 20 do
				advance(tick_rate.TICK_DELTA, watch)
				if told == false and geometry.flatten(unit.position - lab.position):Dot(out) > 0 then
					told = true
					unit.orders = { { kind = "move", position = behind, target_id = nil } }
				end
			end
			report.exit_seconds = round(now() - began, 2)
			report.exit_direction_out = round(geometry.flatten(unit.position - start).Unit:Dot(out), 3)
			report.released_at = local_of(unit.position)
			report.order_kept = #unit.orders > 0 and unit.orders[#unit.orders].position == behind

			local released = now()
			-- behind it, a unit the lab did not make, sent the same way through it, for how deep the lab lets anything in
			local control = spawn_resting(unit_name, OWN, unit.position.X + out.X * 8, unit.position.Z + out.Z * 8)
			control.orders = { { kind = "move", position = behind, target_id = nil } }
			local deepest = 0
			local control_deepest = 0
			advance(args.seconds or 12, function()
				deepest = math.max(deepest, penetration(unit))
				control_deepest = math.max(control_deepest, penetration(control))
				watch()
			end)
			report.deepest_in_lab_after = round(deepest, 2)
			report.control_deepest_in_lab = round(control_deepest, 2)
			report.ended_at = local_of(unit.position)
			report.second_blueprint_after = if second_placed ~= nil then round(second_placed - released, 2) else "never"
			findings[`facing_{quarter}`] = report
			pass = pass
				and report.exiting
				and report.exit_direction_out > 0.9
				and report.order_kept
				and deepest <= control_deepest + 0.1
				and second_placed ~= nil

			clear_world()
		end
	end)
	findings.pass = pass
	return findings
end

-- Orders given to a lab, the way `commands` gives them: they stay in the lab's own queue, which the lab never
-- carries out, and each unit it makes takes a copy of them once it is out, and carries them out to the last stop.
local function lab_orders(args: Args): Findings
	local lab_name = args.lab or "bot_lab"
	local unit_name = args.unit or "grunt"
	local findings: Findings = {}

	local result: Findings = {}
	with_switch(NOCOST, true, function()
		local lab = put_lab(lab_name, 0)
		local first_stop = heightmap.ground_position(20, 40)
		local last_stop = heightmap.ground_position(-20, 60)
		orders.issue(lab, { { kind = "move", position = first_stop, target_id = nil } }, false, false)
		orders.issue(lab, { { kind = "move", position = last_stop, target_id = nil } }, true, false)
		local lab_at = lab.position

		local before = newest_of(lab.team, unit_name)
		production.enqueue(lab, unit_name)
		local unit: Entity? = nil
		local deadline = now() + 60
		while unit == nil and now() < deadline do
			advance(tick_rate.TICK_DELTA)
			local newest = newest_of(lab.team, unit_name)
			if newest ~= before then
				unit = newest
			end
		end
		local made = unit :: Entity
		-- the most orders it was carrying at once, and where the last of them was, seen every tick
		local most_orders = 0
		local ends_at_last_stop = false
		local function watch()
			if #made.orders > most_orders then
				most_orders = #made.orders
				local last = made.orders[#made.orders]
				ends_at_last_stop = last.position ~= nil and geometry.distance_2d(last.position, last_stop) < 1
			end
		end
		while made.state == "blueprint" and now() < deadline do
			advance(tick_rate.TICK_DELTA, watch)
		end
		advance(tick_rate.TICK_DELTA, watch)
		findings.arrived = harness.until_idle(made, args.seconds or 40, watch)
		findings.unit_most_orders = most_orders
		findings.unit_last_order_is_last_stop = ends_at_last_stop
		findings.unit_distance_to_last_stop = round(geometry.distance_2d(made.position, last_stop), 2)
		findings.lab_orders_kept = #lab.orders
		findings.lab_moved = round(geometry.distance_2d(lab.position, lab_at), 3)
		findings.pass = findings.arrived
			and most_orders >= 2
			and ends_at_last_stop
			and findings.unit_distance_to_last_stop < 4
			and findings.lab_orders_kept == 2
			and findings.lab_moved == 0
		result = findings
	end)
	return result
end

-- Buildings as walls (shared/walls.luau, server/obstacles.luau): an Advanced Fusion Reactor, or `args.building`, in the
-- middle of open ground, and a Grunt, or `args.unit`, `args.distance` studs (40) to one side of it. Four walks, each
-- for up to `args.seconds` (30): `routed` to the far side by a route as a player's move gets one (`pathfinder.route`);
-- `straight` to the far side by a bare move, as though its route had been laid before the building went down, which it
-- has to find its own way round once the building holds it up (orders' reroute); `into` the building's middle, which
-- ends at its edge; and `back` again by a route. For each: whether it got there (its orders ran out), how long it took,
-- how far it was left from where it was sent, and on how many ticks its middle was on a wall. Then the building goes,
-- and whether its ground is open again.
local function building_walls(args: Args): Findings
	clear_world()
	local building_name = args.building or "advanced_fusion_reactor"
	local def_name = args.unit or "grunt"
	local def = unit_defs.get(def_name)
	local distance = args.distance or 40
	local seconds = args.seconds or 30
	local building = unkillable(spawn(building_name, OWN, 0, 0))
	local half = unit_defs.footprint_half_extents(unit_defs.get(building_name))
	local walker = spawn(def_name, OWN, 0, -distance)
	advance(tick_rate.TICK_DELTA)
	local blocked_under = walls.blocked_at(0, 0)

	local function walk(to: Vector3, routed: boolean): Findings
		local route: { types.Order } = if routed
			then pathfinder.route(def, walker.position, to, 8000)
			else { { kind = "move", position = to, target_id = nil } }
		orders.issue(walker, route, false, false)
		local started = now()
		local on_wall = 0
		local arrived = harness.until_idle(walker, seconds, function()
			if walls.blocked_at(walker.position.X, walker.position.Z) then
				on_wall += 1
			end
		end)
		local offset = to - walker.position
		return {
			waypoints = #route,
			arrived = arrived,
			seconds = round(now() - started, 2),
			left_to_go = round(Vector3.new(offset.X, 0, offset.Z).Magnitude, 1),
			ticks_on_wall = on_wall,
			ended_at = { round(walker.position.X, 1), round(walker.position.Z, 1) },
		}
	end
	local far = heightmap.ground_position(0, distance)
	local near = heightmap.ground_position(0, -distance)
	local routed = walk(far, true)
	local straight = walk(near, false)
	local into = walk(building.position, false)
	-- how far from the building's edge the walk into it stopped
	local rest = geometry.flatten(walker.position - building.position)
	local into_gap = round(math.max(math.abs(rest.X) - half.X, math.abs(rest.Z) - half.Y), 2)
	local back = walk(far, true)

	deaths.destroy(building, "removed")
	advance(tick_rate.TICK_DELTA)
	local open_after = walls.blocked_at(0, 0) == false
	deaths.destroy(walker, "removed")
	advance(tick_rate.TICK_DELTA)

	local all_walked = true
	for _, walked in { routed, straight, into, back } do
		all_walked = all_walked and walked.arrived == true and walked.ticks_on_wall == 0
	end
	return {
		blocked_under = blocked_under,
		routed = routed,
		straight = straight,
		into = into,
		into_gap = into_gap,
		back = back,
		open_after = open_after,
		pass = blocked_under
			and all_walked
			and routed.left_to_go < 2
			and straight.left_to_go < 2
			and back.left_to_go < 2
			and into_gap < unit_defs.collider_radius(def) + world_scale.CELL_STUDS
			and open_after,
	}
end

local TESTS: { [string]: Test } = {
	move_route = { run = move_route },
	walk_orders = { run = walk_orders },
	lab_exit = { run = lab_exit },
	lab_orders = { run = lab_orders },
	building_walls = { run = building_walls },
}

return table.freeze(TESTS)
