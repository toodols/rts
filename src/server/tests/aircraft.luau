--!strict
-- Tests of how aircraft fly: fighters and bombers on their wings, at the map's edge, under fire, and hovering
-- aircraft keeping round what they work on or shoot at.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local map_state = require(ReplicatedStorage.Shared.map_state)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)

local state = require(ServerScriptService.Server.state)
local orders = require(ServerScriptService.Server.orders)
local movement = require(ServerScriptService.Server.movement)
local damage = require(ServerScriptService.Server.damage)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local ENEMY = harness.ENEMY
local advance = harness.advance
local now = harness.now
local round = harness.round
local spawn = harness.spawn
local unkillable = harness.unkillable
local damage_to = harness.damage_to
local shots_of = harness.shots_of
local spawn_resting = harness.spawn_resting

type Entity = types.Entity
type TeamId = types.TeamId
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- A plane on its wings never slows below this share of its top speed.
local LEAST_WING_SPEED = 0.5
-- How near the map's edge a plane is on it.
local EDGE_TOUCH = 0.5

-- A Valiant on an attack order against a Hercules it cannot kill, for `args.seconds` (30 by default). From ten
-- seconds in, once it has arrived: how slow it ever went, and how near and far from the Hercules it flew. It should
-- hurt it without ever slowing below LEAST_WING_SPEED of its top speed.
local function fighter(args: Args): Findings
	local prey = unkillable(spawn("hercules", ENEMY, -100, 80))
	local plane = spawn("valiant", OWN, 40, 80)
	advance(tick_rate.TICK_DELTA)
	orders.issue(plane, { { kind = "attack", target_id = prey.id } }, false, false)

	local started = now()
	local slowest, nearest, furthest = math.huge, math.huge, 0
	advance(args.seconds or 30, function()
		if now() - started < 10 then
			return
		end
		local offset = prey.position - plane.position
		local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
		slowest = math.min(slowest, plane.velocity.Magnitude)
		nearest = math.min(nearest, distance)
		furthest = math.max(furthest, distance)
	end)
	local max_speed = unit_defs.get("valiant").max_speed :: number
	return {
		slowest = round(slowest, 2),
		nearest = round(nearest, 1),
		furthest = round(furthest, 1),
		max_speed = round(max_speed, 2),
		damage_to_prey = round(damage_to(prey), 0),
		pass = damage_to(prey) > 0 and slowest >= max_speed * LEAST_WING_SPEED,
	}
end

-- Planes on wings, Whirlwinds and Valiants (or just `args.unit`), sent at the edge of the map every way they can be:
-- just inside every side and corner, each is told to fly into the edge, to turn back for a point just behind it (which
-- has it fly on straight into the edge first, to get room to turn), to fly along the edge, to attack something at the
-- edge (a bombing run for a Whirlwind, a transport flying to the edge for a Valiant), to fight its way to the edge,
-- and to fly a chain of moves from one point on the edge to the next. Best run with `preset = "hooked"`, whose map is
-- small enough that fights often come to its edge. They all fly at once for `args.seconds` (30 by default); aircraft do
-- not run into each other. Once `args.warmup` seconds (3) have passed for them to take off and get up to speed, a plane
-- is slow while, with orders left, it has covered less than a quarter of what it would at full speed over the last
-- second; one that stays slow for more than `args.stuck_seconds` (1) is `stuck`. A plane that turns hard round against
-- the edge is slow for a moment, but never for that long. One that stays within EDGE_TOUCH studs of the edge for more
-- than `args.edge_seconds`, or while it has orders for longer than it takes it to turn right round and half a second
-- more, is `pinned_to_edge`. One that has landed on the edge with nothing to do is neither. A plane that has landed
-- right on the edge facing off the map is also sent back to the middle (`takeoff_from_edge`). Every plane that was
-- either, what it was told, where and for how long; any plane that left the map; and the longest any plane was slow,
-- and on the edge, whether or not too long. None should be stuck, pinned or off the map. `args.trace` follows one
-- plane (see below).
local function wing_edges(args: Args): Findings
	local hx, hz = heightmap.half_extents()
	local margin = args.margin or 4
	local units: { string } = if typeof(args.unit) == "string" then { args.unit } else { "whirlwind", "valiant" }

	local function spawn_facing(def_name: string, team: TeamId, at: Vector3, toward: Vector3): Entity
		local ground = heightmap.ground_position(at.X, at.Z)
		return state.create_entity(def_name, team, ground, math.atan2(toward.X, toward.Z), "active")
	end
	local function inside(point: Vector3): Vector3
		return Vector3.new(
			math.clamp(point.X, -hx + margin, hx - margin),
			0,
			math.clamp(point.Z, -hz + margin, hz - margin)
		)
	end

	type Case = {
		plane: Entity,
		name: string,
		samples: { Vector3 },
		stuck_for: number,
		worst: number,
		at: Vector3?,
		from: Vector3?,
		speed: number,
		on_edge_for: number,
		longest_on_edge: number,
		left_map: boolean,
	}
	local cases: { Case } = {}
	local pending: { () -> () } = {}
	local function watch(plane: Entity, name: string)
		table.insert(cases, {
			plane = plane,
			name = name,
			samples = {},
			stuck_for = 0,
			worst = 0,
			at = nil,
			from = nil,
			speed = 0,
			on_edge_for = 0,
			longest_on_edge = 0,
			left_map = false,
		})
	end
	for _, unit in units do
		for sx = -1, 1 do
			for sz = -1, 1 do
				if sx == 0 and sz == 0 then
					continue
				end
				local edge = inside(Vector3.new(sx * hx, 0, sz * hz))
				local inward = -Vector3.new(sx, 0, sz).Unit
				local along = Vector3.new(-inward.Z, 0, inward.X)
				local where = `{unit} at ({sx},{sz})`
				local function add(name: string, from: Vector3, toward: Vector3, give: (Entity) -> ())
					local plane = spawn_facing(unit, OWN, inside(from), toward)
					watch(plane, `{name}, {where}`)
					table.insert(pending, function()
						give(plane)
					end)
				end
				local function move_to(point: Vector3): types.Order
					return { kind = "move", position = heightmap.ground_position(point.X, point.Z), target_id = nil }
				end

				add("into_edge", edge + inward * 40, -inward, function(plane)
					orders.issue(plane, { move_to(edge) }, false, false)
				end)
				add("turn_back", edge + inward * 25, -inward, function(plane)
					orders.issue(plane, { move_to(inside(edge + inward * 45)) }, false, false)
				end)
				add("along_edge", edge, along, function(plane)
					orders.issue(plane, { move_to(inside(edge + along * 1000)) }, false, false)
				end)
				add("fight_edge", edge + inward * 40, -inward, function(plane)
					orders.issue(
						plane,
						{ { kind = "fight", position = heightmap.ground_position(edge.X, edge.Z) } },
						false,
						false
					)
				end)
				add("queued", edge + along * 30, -along, function(plane)
					orders.issue(plane, {
						move_to(inside(edge - along * 30)),
						move_to(inside(edge + along * 30)),
						move_to(edge),
						move_to(inside(edge - along * 60)),
					}, false, false)
				end)
				-- landed right on the edge, facing off the map, and sent back to the middle
				local brink = Vector3.new(math.clamp(sx * hx, -hx, hx), 0, math.clamp(sz * hz, -hz, hz))
				local landed = spawn_facing(unit, OWN, brink, -inward)
				watch(landed, `takeoff_from_edge, {where}`)
				table.insert(pending, function()
					orders.issue(landed, { move_to(Vector3.zero) }, false, false)
				end)
				if unit == "whirlwind" then
					local target = unkillable(spawn("solar_collector", ENEMY, edge.X, edge.Z))
					add("attack_edge", edge + inward * 60, -inward, function(plane)
						orders.issue(plane, { { kind = "attack", target_id = target.id } }, false, false)
					end)
				else
					local prey = unkillable(spawn_facing("hercules", ENEMY, edge + inward * 50, -inward))
					table.insert(pending, function()
						orders.issue(prey, { move_to(edge) }, false, false)
					end)
					add("attack_edge", edge + inward * 70, -inward, function(plane)
						orders.issue(plane, { { kind = "attack", target_id = prey.id } }, false, false)
					end)
				end
			end
		end
	end
	advance(tick_rate.TICK_DELTA)
	for _, give in pending do
		give()
	end

	local per_second = math.round(1 / tick_rate.TICK_DELTA)
	-- they start on the ground, and are slow until they have taken off and got up to speed
	local warmup = args.warmup or 3
	local started = now()
	-- `args.trace` names a case (as it is reported, like "attack_edge, valiant at (1,1)"): where that plane is, where it
	-- heads, and what its order is aimed at, every quarter second, for working out what it does
	local traced: Case? = nil
	for _, case in cases do
		if case.name == args.trace then
			traced = case
		end
	end
	local trace = {}
	local ticks = 0
	advance(args.seconds or 30, function()
		ticks += 1
		if traced ~= nil and ticks % math.max(1, math.round(0.25 / tick_rate.TICK_DELTA)) == 0 then
			local plane = traced.plane
			local order = plane.orders[1]
			local aim = if order == nil
				then nil
				elseif order.target_id ~= nil then (state.get(order.target_id) or plane).position
				else order.position
			table.insert(
				trace,
				`{round(now() - started, 2)}: at ({round(plane.position.X, 1)}, {round(plane.position.Z, 1)})`
					.. ` facing {round(math.deg(plane.facing) % 360, 0)} speed {round(plane.velocity.Magnitude, 1)}`
					.. (if aim ~= nil then ` aim ({round(aim.X, 1)}, {round(aim.Z, 1)})` else " no order")
			)
		end
		if now() - started < warmup then
			return
		end
		for _, case in cases do
			local plane = case.plane
			local at = plane.position
			if heightmap.in_bounds(at.X, at.Z) == false then
				case.left_map = true
			end
			if #plane.orders > 0 and (math.abs(at.X) >= hx - EDGE_TOUCH or math.abs(at.Z) >= hz - EDGE_TOUCH) then
				case.on_edge_for += tick_rate.TICK_DELTA
				case.longest_on_edge = math.max(case.longest_on_edge, case.on_edge_for)
			else
				case.on_edge_for = 0
			end
			table.insert(case.samples, at)
			if #case.samples > per_second + 1 then
				table.remove(case.samples, 1)
			end
			if #case.samples <= per_second or #plane.orders == 0 then
				case.stuck_for = 0
				continue
			end
			local moved = at - case.samples[1]
			local covered = Vector3.new(moved.X, 0, moved.Z).Magnitude
			if covered < 0.25 * (unit_defs.get(plane.def_name).max_speed :: number) then
				case.stuck_for += tick_rate.TICK_DELTA
				if case.stuck_for > case.worst then
					case.worst = case.stuck_for
					case.at = at
					case.from = case.samples[1]
					case.speed = plane.velocity.Magnitude
				end
			else
				case.stuck_for = 0
			end
		end
	end)

	local stuck_limit = args.stuck_seconds or 1
	local edge_limit: number? = args.edge_seconds
	local stuck = {}
	local pinned = {}
	local left = {}
	local slowest: Case? = nil
	local edgiest: Case? = nil
	for _, case in cases do
		if slowest == nil or case.worst > slowest.worst then
			slowest = case
		end
		if edgiest == nil or case.longest_on_edge > edgiest.longest_on_edge then
			edgiest = case
		end
		local wings = (unit_defs.get(case.plane.def_name).air :: any).wings :: types.Wings
		if case.longest_on_edge > (edge_limit or math.pi / wings.turn_rate + 0.5) then
			table.insert(pinned, `{case.name}: {round(case.longest_on_edge, 1)}s on the edge`)
		end
		if case.worst > stuck_limit then
			local at = case.at :: Vector3
			local from = case.from :: Vector3
			table.insert(
				stuck,
				`{case.name}: {round(case.worst + 1, 1)}s at ({round(at.X, 1)}, {round(at.Z, 1)}), a second after`
					.. ` ({round(from.X, 1)}, {round(from.Z, 1)}), flying at {round(case.speed, 1)}`
			)
		end
		if case.left_map then
			table.insert(left, case.name)
		end
	end
	return {
		preset = map_state.preset().name,
		half_extents = { round(hx, 1), round(hz, 1) },
		planes = #cases,
		stuck = stuck,
		pinned_to_edge = pinned,
		left_map = left,
		longest_slow = if slowest ~= nil and slowest.worst > 0
			then `{round(slowest.worst, 2)}s, {slowest.name}`
			else "none",
		longest_on_edge = if edgiest ~= nil and edgiest.longest_on_edge > 0
			then `{round(edgiest.longest_on_edge, 2)}s, {edgiest.name}`
			else "none",
		trace = if traced ~= nil then trace else nil,
		pass = #stuck == 0 and #pinned == 0 and #left == 0,
	}
end

-- A transport, a Hercules or `args.unit`, flying out one way at full speed, is told to come back the other way while
-- it is hit every tick, the way steady fire hits it (`movement.set_impulse`, as `beams` does it). How far it got back
-- toward where it was sent, and how far past where it was turned it drifted on the way out first: under fire it should
-- still turn and come back.
local function hit_control(args: Args): Findings
	local transport = unkillable(spawn(args.unit or "hercules", OWN, 0, 0))
	advance(tick_rate.TICK_DELTA)
	local out = heightmap.ground_position(0, 400)
	orders.issue(transport, { { kind = "move", position = out, target_id = nil } }, false, false)
	advance(args.run_up or 4)
	local turned_at = transport.position
	local back = heightmap.ground_position(0, -100)
	orders.issue(transport, { { kind = "move", position = back, target_id = nil } }, false, false)
	local furthest_out = 0
	advance(args.seconds or 8, function()
		movement.set_impulse(transport, 0.5)
		furthest_out = math.max(furthest_out, transport.position.Z - turned_at.Z)
	end)
	local came_back = turned_at.Z - transport.position.Z
	return {
		drifted_out = round(furthest_out, 1),
		came_back = round(came_back, 1),
		heading_back = transport.velocity.Z < 0,
		pass = came_back > 0 and transport.velocity.Z < 0,
	}
end

-- How evenly `points` sit round `center`: how many of `sectors` equal slices of the circle round it hold at least one,
-- the widest gap between two of them going round, in degrees, and each one's distance to its nearest neighbour, least
-- and on average, and to the middle, least and most.
local function spread_round(center: Vector3, points: { Vector3 }, sectors: number): Findings
	local angles: { number } = {}
	local occupied: { [number]: boolean } = {}
	local nearest_middle, furthest_middle = math.huge, 0
	for _, point in points do
		local away = Vector3.new(point.X - center.X, 0, point.Z - center.Z)
		local angle = math.atan2(away.Z, away.X) % (2 * math.pi)
		table.insert(angles, angle)
		occupied[math.floor(angle / (2 * math.pi) * sectors)] = true
		nearest_middle = math.min(nearest_middle, away.Magnitude)
		furthest_middle = math.max(furthest_middle, away.Magnitude)
	end
	table.sort(angles)
	local widest_gap = 0
	for index, angle in angles do
		local following = if index < #angles then angles[index + 1] else angles[1] + 2 * math.pi
		widest_gap = math.max(widest_gap, following - angle)
	end
	local least_apart, total_apart = math.huge, 0
	for index, point in points do
		local nearest = math.huge
		for other_index, other in points do
			if other_index ~= index then
				nearest = math.min(nearest, Vector3.new(point.X - other.X, 0, point.Z - other.Z).Magnitude)
			end
		end
		least_apart = math.min(least_apart, nearest)
		total_apart += nearest
	end
	local filled = 0
	for _ in occupied do
		filled += 1
	end
	return {
		sectors_filled = filled,
		sectors = sectors,
		widest_gap_degrees = round(math.deg(widest_gap), 0),
		nearest_neighbour_least = round(least_apart, 2),
		nearest_neighbour_mean = round(total_apart / math.max(#points, 1), 2),
		from_middle = { round(nearest_middle, 1), round(furthest_middle, 1) },
	}
end

-- `args.count` (40) flying builders, `args.unit` or Advanced Construction Aircraft, all sent from one clump to assist
-- one blueprint, `args.target` or an Epic Fusion Reactor, for `args.seconds` (90). How they are spread round it once
-- they have arrived (`arrived`, ten seconds in) and at the end (`settled`), how many still assist it, and the range
-- they have to keep within. By the end they should all still be assisting it, spread all the way round it, none further
-- from its middle than its half width and the build range.
local function air_ring(args: Args): Findings
	harness.ensure_team(OWN)
	local unit = args.unit or "advanced_construction_aircraft"
	local count = args.count or 40
	local blueprint =
		state.create_entity(args.target or "epic_fusion_reactor", OWN, heightmap.ground_position(0, 0), 0, "blueprint")
	-- someone has made a start on it, or it would decay away before they got there, nobody having fed it
	blueprint.build_progress = blueprint.def.buildpower_cost * 0.01
	local builders: { Entity } = {}
	for index = 1, count do
		local builder = spawn(unit, OWN, -90 + (index % 7) * 2, -6 + math.floor(index / 7) * 2)
		table.insert(builders, builder)
	end
	advance(tick_rate.TICK_DELTA)
	for _, builder in builders do
		orders.issue(builder, { { kind = "assist", target_id = blueprint.id } }, false, false)
	end
	local function positions(): { Vector3 }
		local found: { Vector3 } = {}
		for _, builder in builders do
			table.insert(found, builder.position)
		end
		return found
	end
	advance(10)
	local arrived = spread_round(blueprint.position, positions(), 12)
	-- how far they go between picks, on average, near the end: they keep drifting rather than sit still
	advance((args.seconds or 90) - 15)
	local before = positions()
	advance(5)
	local after = positions()
	local drift = 0
	for index, point in after do
		drift += Vector3.new(point.X - before[index].X, 0, point.Z - before[index].Z).Magnitude
	end
	local assisting = 0
	for _, builder in builders do
		local order = builder.orders[1]
		if order ~= nil and order.kind == "assist" then
			assisting += 1
		end
	end
	local collider = unit_defs.get(blueprint.def_name).collider
	local half_width = if collider.shape == "box" then collider.width / 2 else collider.radius
	local settled = spread_round(blueprint.position, after, 12)
	return {
		arrived = arrived,
		settled = settled,
		mean_drift_last_5s = round(drift / count, 2),
		still_assisting = assisting,
		count = count,
		blueprint_state = blueprint.state,
		blueprint_half_width = half_width,
		build_range = order_kinds.BUILD_RANGE,
		pass = assisting == count
			and settled.sectors_filled == settled.sectors
			and settled.from_middle[2] <= half_width + order_kinds.BUILD_RANGE,
	}
end

-- A gunship, `args.unit` or a Tyrannus, `args.count` of them (1), attacking an enemy that cannot die, `args.target` or
-- a Solar Collector, for `args.seconds` (60). From fifteen seconds in, once they are there: how near and far from it
-- they kept, how far round it the first went in all (so how many times it circled it), how slow it ever went, and the
-- damage done. They should hurt it, and circle it as they fire unless it is a building, which cannot move out of their
-- reach and so is shot from wherever they first can (orders.luau's run_attack).
local function gunship_ring(args: Args): Findings
	local unit = args.unit or "tyrannus"
	local target = unkillable(spawn(args.target or "solar_collector", ENEMY, 0, 0))
	local gunships: { Entity } = {}
	for index = 1, args.count or 1 do
		table.insert(gunships, spawn(unit, OWN, -90, (index - 1) * 8))
	end
	advance(tick_rate.TICK_DELTA)
	for _, gunship in gunships do
		orders.issue(gunship, { { kind = "attack", target_id = target.id } }, false, false)
	end
	local started = now()
	local nearest, furthest, slowest = math.huge, 0, math.huge
	local turned = 0
	local last_angle: number? = nil
	advance(args.seconds or 60, function()
		if now() - started < 15 then
			return
		end
		for _, gunship in gunships do
			local away = Vector3.new(gunship.position.X - target.position.X, 0, gunship.position.Z - target.position.Z)
			nearest = math.min(nearest, away.Magnitude)
			furthest = math.max(furthest, away.Magnitude)
		end
		local first = gunships[1]
		slowest = math.min(slowest, first.velocity.Magnitude)
		local angle = math.atan2(first.position.Z - target.position.Z, first.position.X - target.position.X)
		if last_angle ~= nil then
			turned += math.abs((angle - last_angle + math.pi) % (2 * math.pi) - math.pi)
		end
		last_angle = angle
	end)
	local positions: { Vector3 } = {}
	for _, gunship in gunships do
		table.insert(positions, gunship.position)
	end
	local def = unit_defs.get(unit)
	local ground_reach = 0
	if def.weapons ~= nil then
		for _, weapon in def.weapons do
			if weapon.target_layer ~= "air" then
				ground_reach = math.max(ground_reach, weapon.range)
			end
		end
	end
	return {
		distance = { round(nearest, 1), round(furthest, 1) },
		ground_reach = round(ground_reach, 1),
		circled_degrees = round(math.deg(turned), 0),
		slowest = round(slowest, 2),
		max_speed = round(def.max_speed :: number, 2),
		spread = if #positions > 1 then spread_round(target.position, positions, 8) else nil,
		damage_to_target = round(damage_to(target), 0),
		pass = damage_to(target) > 0 and (target.kind == "building" or turned >= 2 * math.pi),
	}
end

-- Anti-air missiles and the ground units round a landing aircraft: a Thistle within reach of an enemy Whirlwind
-- `args.lift` studs (20 by default) over the ground, which it fires at and which then settles among four Thugs packed
-- round it, for `args.seconds` (20 by default); and one Thistle missile's full damage landed straight on a Thug. As in
-- BAR, whose anti-air weapons do damage only to aircraft, a Thug should take no more than weapon_kinds'
-- AA_NON_AIR_DAMAGE from each missile, whether it is hit or the missile goes off beside it.
local function aa_ground_splash(args: Args): Findings
	local launcher = spawn("thistle", OWN, 0, 0)
	local plane = unkillable(spawn_resting("whirlwind", ENEMY, -50, 0))
	plane.position += Vector3.new(0, args.lift or 20, 0)
	local thugs: { Entity } = {}
	for _, offset in { Vector2.new(4, 0), Vector2.new(-4, 0), Vector2.new(0, 4), Vector2.new(0, -4) } do
		table.insert(thugs, unkillable(spawn("thug", ENEMY, -50 + offset.X, offset.Y)))
	end
	local struck = unkillable(spawn("thug", ENEMY, 120, 0))
	advance(tick_rate.TICK_DELTA)
	advance(args.seconds or 20)
	local fired = shots_of(launcher.id, 1)
	local worst = 0
	for _, thug in thugs do
		worst = math.max(worst, damage_to(thug))
	end
	local weapon = (unit_defs.get("thistle").weapons :: { types.Weapon })[1]
	damage.hit(struck, weapon.damage, weapon, launcher.id, OWN, true)
	return {
		fired = fired,
		plane_landed = plane.position.Y < heightmap.height_at(plane.position.X, plane.position.Z) + 3,
		damage_to_plane = round(damage_to(plane), 1),
		most_to_a_thug = round(worst, 1),
		direct_hit_on_thug = round(damage_to(struck), 1),
		pass = damage_to(struck) <= 1 and worst <= math.max(fired, 1),
	}
end

local TESTS: { [string]: Test } = {
	fighter = { run = fighter },
	wing_edges = { run = wing_edges, defaults = { preset = "hooked" } },
	hit_control = { run = hit_control },
	air_ring = { run = air_ring },
	gunship_ring = { run = gunship_ring },
	aa_ground_splash = { run = aa_ground_splash },
}

return table.freeze(TESTS)
