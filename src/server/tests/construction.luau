--!strict
-- Tests of building, reclaiming and raising: builders finding their way to a site, reaching it from where they stand,
-- metal spots and vents, what the map's rocks and trees hold, and rezbots.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local geometry = require(ReplicatedStorage.Shared.geometry)
local spots = require(ReplicatedStorage.Shared.spots)
local starts = require(ReplicatedStorage.Shared.starts)
local order_kinds = require(ReplicatedStorage.Shared.order_kinds)
local build_hotkeys = require(ReplicatedStorage.Shared.build_hotkeys)
local keybinds = require(ReplicatedStorage.Shared.keybinds)
local order_path = require(ReplicatedStorage.Shared.order_path)

local state = require(ServerScriptService.Server.state)
local damage = require(ServerScriptService.Server.damage)
local deaths = require(ServerScriptService.Server.deaths)
local orders = require(ServerScriptService.Server.orders)
local movement = require(ServerScriptService.Server.movement)
local manual_weapons = require(ServerScriptService.Server.manual_weapons)
local targeting = require(ServerScriptService.Server.targeting)
local construction = require(ServerScriptService.Server.construction)
local work = require(ServerScriptService.Server.work)
local placement = require(ServerScriptService.Server.placement)
local resurrection = require(ServerScriptService.Server.resurrection)

local harness = require(script.Parent.harness)

local OWN = harness.OWN
local ENEMY = harness.ENEMY
local UNKILLABLE = harness.UNKILLABLE
local NOCOST = harness.NOCOST
local advance = harness.advance
local now = harness.now
local round = harness.round
local spawn = harness.spawn
local unkillable = harness.unkillable
local lay = harness.lay
local clear_world = harness.clear_world
local until_idle = harness.until_idle
local with_switch = harness.with_switch
local flow_of = harness.flow_of

type Entity = types.Entity
type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

-- A builder that works from where it stands moves no further than this while it does.
local STANDS_STILL = 0.5
-- What a reclaim takes, and pays, is right to within this share of what BAR's numbers say.
local RECLAIM_SLACK = 0.1

-- Whether `value` is `want` to within `share` of it, and a hair more for what rounding leaves.
local function near(value: number, want: number, share: number): boolean
	return math.abs(value - want) <= math.abs(want) * share + 0.1
end

-- The first finished `def_name` of team `team`, if one stands.
local function finished(def_name: string, team: types.TeamId): Entity?
	for _, entity in state.all() do
		if entity.alive and entity.def_name == def_name and entity.team == team and entity.state == "active" then
			return entity
		end
	end
	return nil
end

-- Half of how long something of `def_name` is along z, turned as it is built.
local function half_length(def_name: string): number
	local collider = unit_defs.get(def_name).collider
	return if collider.shape == "box" then collider.length / 2 else collider.radius
end

-- Whether anything of `def_name` of team `team` has gone down, finished or not.
local function placed(def_name: string, team: types.TeamId): boolean
	for _, entity in state.all() do
		if entity.def_name == def_name and entity.team == team then
			return true
		end
	end
	return false
end

-- A build order given the way a player's is (`harness.player_route`): a Construction Bot, or `args.unit`, at the foot
-- of the plateau told to put a Solar Collector, or `args.building`, up on it, where it has to find its way round. How
-- many waypoints it was given ahead of the build, whether the blueprint went down, and whether the order was dropped.
-- It should get there and put it down. `args.straight` gives it the bare build order, with no route ahead of it, for
-- comparison.
local function build_route(args: Args): Findings
	local building = args.building or "solar_collector"
	local result: Findings = {}
	with_switch(NOCOST, true, function()
		local builder = spawn(args.unit or "construction_bot", OWN, 190, -120)
		advance(tick_rate.TICK_DELTA)
		-- snapped to the grid the way a player's placement is
		local site = placement.resolve_center(building, args.x or 130, args.z or -110, 0, builder)
			or heightmap.ground_position(args.x or 130, args.z or -110)
		local placement_ok, placement_reason = placement.can_place(building, site, 0, builder)
		local order: types.Order = { kind = "build", position = site, target_id = nil, def_name = building, facing = 0 }
		local steps, sent = harness.player_route(builder, order)
		if args.straight then
			steps = { steps[#steps] }
		end
		orders.issue(builder, steps, false, false)
		local started = now()
		local placed_at: number? = nil
		local dropped = false
		local deadline = now() + (args.seconds or 60)
		while now() < deadline and placed_at == nil and dropped == false do
			advance(tick_rate.TICK_DELTA)
			if placed(building, OWN) then
				placed_at = now()
			end
			dropped = placed_at == nil and #builder.orders == 0
		end
		result = {
			waypoints_sent = sent,
			moves_ahead_of_build = #steps - 1,
			placed = placed_at ~= nil,
			seconds = round((placed_at or now()) - started, 2),
			dropped = dropped,
			site_placeable = placement_ok,
			site_reason = placement_reason,
			left_to_go = round(Vector3.new(site.X - builder.position.X, 0, site.Z - builder.position.Z).Magnitude, 1),
			pass = placed_at ~= nil,
		}
	end)
	return result
end

-- A build order given the way a player's is (`harness.player_route`) for a site up a cliff that a Construction Bot,
-- or `args.unit`, has in reach from where it stands, but could only walk up to the long way round. Found on the map:
-- a spot the bot can stand on with a site for a Solar Collector, or `args.building`, within its reach that it cannot
-- go straight to and that a search finds a way to. How many waypoints the way to the site itself has, how many were
-- sent ahead of the build (none: it builds from where it stands), whether the blueprint went down, and how far the bot
-- went from where it started (nowhere). Played on koth unless another `preset` is given: the usual map's only such
-- sites were across shallow water, which a bot now wades.
local function build_in_reach(args: Args): Findings
	local building = args.building or "solar_collector"
	local unit = args.unit or "construction_bot"
	local def = unit_defs.get(unit)
	local reach = order_kinds.reach(def, "build")
	local searches = 0
	local site: Vector3? = nil
	local full_route = 0
	local from = harness.find_spot(function(x: number, z: number): boolean
		if searches >= (args.searches or 200) or heightmap.water_depth(x, z) > 0 then
			return false
		end
		local here = heightmap.ground_position(x, z)
		if pathfinder.has_straight_path(def, here, heightmap.ground_position(x + 4, z)) == false then
			return false
		end
		for index = 0, 7 do
			local angle = index * math.pi / 4
			local center = placement.resolve_center(
				building,
				x + math.cos(angle) * reach * 0.8,
				z + math.sin(angle) * reach * 0.8,
				0,
				nil
			)
			if
				center ~= nil
				and geometry.distance_2d(here, center) <= reach
				and pathfinder.has_straight_path(def, here, center) == false
				and placement.can_place(building, center, 0, nil, OWN)
			then
				searches += 1
				local steps, searched = pathfinder.route(def, here, center, 8000)
				local last = steps[#steps].position
				if searched and #steps >= 3 and last ~= nil and geometry.distance_2d(last, center) <= reach then
					site = center
					full_route = #steps - 1
					return true
				end
			end
		end
		return false
	end)
	assert(from ~= nil and site ~= nil, `no site in reach up a cliff on this map after {searches} searches`)

	local result: Findings = {}
	with_switch(NOCOST, true, function()
		local builder = spawn(unit, OWN, from.X, from.Z)
		local start = builder.position
		advance(tick_rate.TICK_DELTA)
		local order: types.Order = { kind = "build", position = site, target_id = nil, def_name = building, facing = 0 }
		local steps, sent = harness.player_route(builder, order)
		orders.issue(builder, steps, false, false)
		local started = now()
		local placed_at: number? = nil
		local furthest = 0
		local deadline = now() + (args.seconds or 30)
		while now() < deadline and placed_at == nil do
			advance(tick_rate.TICK_DELTA)
			furthest = math.max(furthest, geometry.distance_2d(builder.position, start))
			if placed(building, OWN) then
				placed_at = now()
			end
		end
		result = {
			from = { round(start.X, 1), round(start.Z, 1) },
			site = { round(site.X, 1), round(site.Z, 1) },
			distance = round(geometry.distance_2d(start, site), 1),
			reach = round(reach, 1),
			full_route_waypoints = full_route,
			waypoints_sent = sent,
			moves_ahead_of_build = #steps - 1,
			placed = placed_at ~= nil,
			seconds = round((placed_at or now()) - started, 2),
			furthest_from_start = round(furthest, 1),
			pass = #steps == 1 and placed_at ~= nil and furthest <= STANDS_STILL,
		}
	end)
	return result
end

-- A Construction Bot, or `args.unit`, told to build a Fusion Reactor, or `args.building`, whose middle is out of its
-- reach but whose edge is in it, and then to assist the blueprint from as far out again on another side. A builder has
-- a blueprint in reach once its reach touches any part of its collider, so it should start both without taking a step.
-- Whether the blueprint went down and was being worked on by each, and how far each bot moved.
local function build_reach_edge(args: Args): Findings
	local building = args.building or "fusion_reactor"
	local unit = args.unit or "construction_bot"
	local reach = order_kinds.reach(unit_defs.get(unit), "build")
	local collider = unit_defs.get(building).collider
	local half = if collider.shape == "box" then collider.width / 2 else collider.radius
	-- past the middle's reach by half of the way to the edge
	local offset = reach + half * 0.5
	local site: Vector3? = nil
	local from = harness.find_spot(function(x: number, z: number): boolean
		if heightmap.water_depth(x, z) > 0 or heightmap.water_depth(x + offset, z) > 0 then
			return false
		end
		local center = placement.resolve_center(building, x + offset, z, 0, nil)
		if
			center == nil
			or heightmap.water_depth(center.X - offset, center.Z) > 0
			or heightmap.water_depth(center.X + offset, center.Z) > 0
			or placement.can_place(building, center, 0, nil, OWN) == false
		then
			return false
		end
		site = center
		return true
	end)
	assert(from ~= nil and site ~= nil, "no open ground for the building on this map")
	local center = site :: Vector3
	-- paying for it as usual, so that it is still a blueprint for the second bot to help with
	harness.ensure_team(OWN)
	local builder = spawn(unit, OWN, center.X - offset, center.Z)
	advance(tick_rate.TICK_DELTA)
	local start = builder.position
	orders.issue(
		builder,
		{ { kind = "build", position = center, target_id = nil, def_name = building, facing = 0 } },
		false,
		false
	)
	local blueprint: Entity? = nil
	for _ = 1, 30 do
		advance(tick_rate.TICK_DELTA)
		for _, entity in state.all() do
			if entity.def_name == building and entity.team == OWN then
				blueprint = entity
			end
		end
	end
	local build_moved = geometry.distance_2d(builder.position, start)
	local building_it = blueprint ~= nil and work.recent(builder.id, "build") == blueprint

	-- a second bot assisting from out past the other side
	local helper = spawn(unit, OWN, center.X + offset, center.Z)
	advance(tick_rate.TICK_DELTA)
	local helper_start = helper.position
	local assisted = false
	if blueprint ~= nil then
		orders.issue(helper, { { kind = "assist", position = nil, target_id = blueprint.id } }, false, false)
		for _ = 1, 30 do
			advance(tick_rate.TICK_DELTA)
			if work.recent(helper.id, "build") == blueprint then
				assisted = true
			end
		end
	end
	local helper_moved = geometry.distance_2d(helper.position, helper_start)
	return {
		reach = round(reach, 1),
		half_width = round(half, 1),
		distance_to_middle = round(offset, 1),
		placed = blueprint ~= nil,
		building_it = building_it,
		builder_moved = round(build_moved, 2),
		assisted = assisted,
		helper_moved = round(helper_moved, 2),
		pass = building_it and build_moved <= STANDS_STILL and assisted and helper_moved <= STANDS_STILL,
	}
end

-- Construction Bots, `args.builders` of them (1 by default) or of `args.unit`, given a bare build order (no route) for a
-- Solar Collector, or `args.building`, `args.gap` studs past the far side of an Advanced Fusion Reactor, or
-- `args.obstacle`, so that they walk into the obstacle, which is a wall (server/obstacles.luau), are held at its edge,
-- and find their way round it from there (orders' reroute), or build from the edge of their reach over it. With
-- `args.paid` it is paid for and takes its time; otherwise nocost finishes it on the spot. For `args.seconds` (30 by
-- default), over all of them: how often one turned more than a quarter turn in one tick (each should do so no more
-- than once, as it turns back to go round, and never flip round and back); on how many ticks one was moving back,
-- away from the site; how close one got to the obstacle; and whether the blueprint went down, which it should.
-- `args.trace` also gives where the first was, which way it faced and its first order, each half second.
local function builder_blocked(args: Args): Findings
	local building = args.building or "solar_collector"
	local obstacle_name = args.obstacle or "advanced_fusion_reactor"
	local def = unit_defs.get(args.unit or "construction_bot")
	local reach = order_kinds.reach(def, "build")
	local obstacle_half = half_length(obstacle_name)
	local site_half = half_length(building)
	harness.ensure_team(OWN)
	local result: Findings = {}
	with_switch(NOCOST, args.paid ~= true, function()
		local obstacle = unkillable(spawn(obstacle_name, OWN, 0, 0))
		local site_z = obstacle_half + site_half + (args.gap or 4)
		local builders: { Entity } = {}
		local count = args.builders or 1
		for index = 1, count do
			local x = (index - (count + 1) / 2) * 3
			table.insert(builders, spawn(args.unit or "construction_bot", OWN, x, -(obstacle_half + reach + 10)))
		end
		advance(tick_rate.TICK_DELTA)
		local site = heightmap.ground_position(0, site_z)
		for _, builder in builders do
			orders.issue(
				builder,
				{ { kind = "build", position = site, target_id = nil, def_name = building, facing = 0 } },
				false,
				false
			)
		end
		local flips, ticks, pushed_back = 0, 0, 0
		local closest = math.huge
		local went_down = false
		local facings: { number } = {}
		for index, builder in builders do
			facings[index] = builder.facing
		end
		local trace: { string } = {}
		advance(args.seconds or 30, function()
			ticks += 1
			local first = builders[1]
			if args.trace and ticks % 10 == 0 then
				local order = first.orders[1]
				table.insert(
					trace,
					`{round(first.position.X, 1)},{round(first.position.Z, 1)} f{math.round(math.deg(first.facing))} {if order
						then order.kind
						else "-"}`
				)
			end
			for index, builder in builders do
				local turn = (builder.facing - facings[index] + math.pi) % (2 * math.pi) - math.pi
				if math.abs(turn) > math.pi / 2 then
					flips += 1
				end
				facings[index] = builder.facing
				if
					builder.velocity.Magnitude > movement.MOVEMENT_SETTLE_SPEED
					and builder.velocity:Dot(site - builder.position) < 0
				then
					pushed_back += 1
				end
				closest = math.min(closest, math.abs(builder.position.Z - obstacle.position.Z) - obstacle_half)
			end
			went_down = went_down or placed(building, OWN)
		end)
		result = {
			reach = round(reach, 1),
			obstacle_half = round(obstacle_half, 1),
			site_z = round(site_z, 1),
			flips = flips,
			pushed_back = pushed_back,
			ticks = ticks,
			closest_to_obstacle = round(closest, 2),
			placed = went_down,
			trace = if args.trace then table.concat(trace, " | ") else nil,
			pass = flips <= count and went_down,
		}
	end)
	return result
end

-- A mex placed at a metal spot, the way `commands` resolves a player's: queued by one builder, then placed at the same
-- spot again by that builder, by another builder, and by no builder. Only the builder that queued it should snap past
-- it: another builder's queue takes a spot from nobody else.
local function mex_queue_snap(_args: Args): Findings
	local spot = spots.all("metal")[1].position
	local first = spawn("construction_bot", OWN, spot.X + 10, spot.Z + 10)
	local second = spawn("construction_bot", OWN, spot.X + 10, spot.Z + 10)
	advance(tick_rate.TICK_DELTA)
	local queued = placement.resolve_center("metal_extractor", spot.X, spot.Z, 0, first) :: Vector3
	orders.issue(
		first,
		{ { kind = "build", position = queued, target_id = nil, def_name = "metal_extractor", facing = 0 } },
		false,
		false
	)
	local same = placement.resolve_center("metal_extractor", spot.X, spot.Z, 0, first)
	local other = placement.resolve_center("metal_extractor", spot.X, spot.Z, 0, second)
	local nobody = placement.resolve_center("metal_extractor", spot.X, spot.Z, 0, nil)
	local findings: Findings = {
		same_builder_snaps_past = same ~= nil and same ~= queued,
		other_builder_takes_it = other == queued,
		no_builder_takes_it = nobody == queued,
	}
	findings.pass = findings.same_builder_snaps_past
		and findings.other_builder_takes_it
		and findings.no_builder_takes_it
	return findings
end

-- Reclaimables (`scenery`, `reclaim`), on the map as it is strewn (the test starts with `scenery`). How many of each the
-- map was strewn with, and whether each has its twin across the middle, as they all should. Then a Construction Bot,
-- or `args.unit`, reclaims a tree and a large rock laid beside it: what each paid out over the base income, which should
-- be what it holds, and how long it took, which should be BAR's reclaimTime / workertime. Then a rock can be neither
-- raised, shot, blown up nor disintegrated; it blocks a building, but not one its builder's team puts over it; and an
-- area reclaim takes the rocks in it.
local function reclaimables(args: Args): Findings
	local counts: { [string]: number } = {}
	local unpaired = 0
	local positions: { Vector3 } = {}
	-- what the map was strewn with has not been through a step yet
	for _, entity in state.all() do
		if entity.kind == "reclaimable" then
			counts[entity.def_name] = (counts[entity.def_name] or 0) + 1
			table.insert(positions, entity.position)
		end
	end
	for _, at in positions do
		local twinned = false
		for _, other in positions do
			if math.abs(other.X + at.X) < 0.01 and math.abs(other.Z + at.Z) < 0.01 then
				twinned = true
				break
			end
		end
		if twinned == false then
			unpaired += 1
		end
	end
	clear_world()

	local team = harness.ensure_team(OWN)
	local builder = spawn(args.unit or "construction_bot", OWN, 0, 0)
	local buildpower = (unit_defs.get(builder.def_name).builder :: types.Builder).buildpower

	-- what one reclaim order brings in over what the team would have made anyway
	local function reclaim_one(target: Entity): Findings
		advance(tick_rate.TICK_DELTA)
		harness.set_bank(OWN, { metal = 0, energy = 0 })
		local started = now()
		orders.issue(builder, { { kind = "reclaim", position = nil, target_id = target.id } }, false, false)
		until_idle(builder, 60)
		local seconds = now() - started
		local def = unit_defs.get(target.def_name)
		local metal = team.metal - team.metal_income * seconds
		local energy = team.energy - team.energy_income * seconds
		local bar_seconds = def.buildpower_cost * state.RECLAIMABLE_BUILDPOWER_FRACTION / buildpower
		return {
			gone = target.alive == false,
			metal = round(metal, 1),
			energy = round(energy, 1),
			seconds = round(seconds, 2),
			bar_seconds = round(bar_seconds, 2),
			holds = { metal = def.metal_cost, energy = def.energy_cost },
			ok = target.alive == false
				and near(metal, def.metal_cost, RECLAIM_SLACK)
				and near(energy, def.energy_cost, RECLAIM_SLACK)
				and near(seconds, bar_seconds, RECLAIM_SLACK),
		}
	end
	local tree = reclaim_one(lay("tree", 5, 0))
	local rock = reclaim_one(lay("large_rock", -6, 0))

	-- it cannot be raised or ordered attacked, but damage wears it away as it does a wreck, leaving nothing and
	-- crediting nobody (BAR's rocks have `damage` health and no `featuredead`)
	local target = lay("rock", 20, 0)
	local rezzer = spawn("graverobber", OWN, 16, 4)
	-- off to the side, so that its disintegrator, fired at a rock, passes nothing else
	local commander = spawn("commander", OWN, 20, -16)
	advance(tick_rate.TICK_DELTA)
	local raisable = resurrection.can_resurrect(rezzer, target)
	local attackable = targeting.is_valid_forced_target(commander, target)
	local rock_health = target.max_health
	damage.apply(target, 1e6, commander.id)
	advance(tick_rate.TICK_DELTA)
	local destroyed_by_damage = target.alive == false
	local credited = commander.kills > 0 or commander.damage_dealt > 0
	local left_behind = 0
	for _, entity in state.all() do
		if entity.alive and geometry.distance_2d(entity.position, target.position) < 2 then
			left_behind += 1
		end
	end
	local swept = lay("rock", 20, 0)
	commander.manual_reload_remaining = 0
	local dgun: any = nil
	with_switch(NOCOST, true, function()
		dgun = manual_weapons.fire(commander, swept.position)
	end)
	advance(tick_rate.TICK_DELTA)
	local destroyed_by_dgun = swept.alive == false
	-- still in the way of anyone else building on it, though its own side's builder clears it off as it comes
	local standing = lay("rock", 20, 0)
	local site = placement.resolve_center("solar_collector", standing.position.X, standing.position.Z, 0, nil)
		or standing.position
	local blocks_others = placement.can_place("solar_collector", site, 0, nil, nil) == false
	local cleared_by_builder = placement.can_place("solar_collector", site, 0, nil, OWN)

	-- an area reclaim takes every rock in its circle
	local field = { lay("small_rock", 30, 10), lay("small_rock", 34, 12), lay("rock", 32, 16) }
	orders.issue(
		builder,
		{ { kind = "area_reclaim", position = heightmap.ground_position(32, 12), target_id = nil, radius = 10 } },
		false,
		false
	)
	until_idle(builder, 60)
	local left = 0
	for _, entity in field do
		if entity.alive then
			left += 1
		end
	end

	return {
		scattered = counts,
		unpaired = unpaired,
		tree = tree,
		large_rock = rock,
		raisable = raisable,
		attackable = attackable,
		rock_health = rock_health,
		destroyed_by_damage = destroyed_by_damage,
		credited = credited,
		left_behind = left_behind,
		dgun = dgun,
		destroyed_by_dgun = destroyed_by_dgun,
		blocks_others = blocks_others,
		cleared_by_builder = cleared_by_builder,
		area_reclaim_left = left,
		pass = #positions > 0
			and unpaired == 0
			and tree.ok
			and rock.ok
			and raisable == false
			and attackable == false
			and rock_health == 700
			and destroyed_by_damage
			and credited == false
			and left_behind == 0
			and destroyed_by_dgun
			and blocks_others
			and cleared_by_builder
			and left == 0,
	}
end

-- Rocks and trees take damage as BAR's features do (unit_defs/reclaimable.luau): a blast burns a tree away, a grunt's
-- beam at an enemy behind a tree strikes the tree first, a Thug's plasma shell flies through a tree on its way to the
-- enemy past it, and nothing shoots at a rock or a tree of its own accord.
local function reclaimables_harmed(_args: Args): Findings
	clear_world()
	harness.ensure_team(OWN)
	harness.ensure_team(ENEMY)

	-- a blast: the tree is gone, with nothing left where it stood
	local blasted = lay("tree", 0, 0)
	local tree_health = blasted.max_health
	damage.blast(blasted.position, 4, nil, function(other: Entity, force: number)
		damage.apply(other, 1000 * force)
	end)
	advance(tick_rate.TICK_DELTA)
	local blast_destroyed = blasted.alive == false

	-- a beam: the tree between the grunt and the enemy takes the shots
	unkillable(harness.spawn_resting("grunt", OWN, 40, 0))
	local shielded = unkillable(harness.spawn_resting("grunt", ENEMY, 56, 0))
	local screen = lay("tree", 48, 0)
	advance(4)
	local beam_hit = screen.alive == false or screen.health < screen.max_health
	local shielded_hurt = harness.damage_to(shielded)

	-- a shell: it flies over and through the tree, which only the blast where it lands could reach, and that is far off
	local thug = unkillable(spawn("thug", OWN, -60, 0))
	local shelled = unkillable(spawn("grunt", ENEMY, -30, 0))
	local passed = lay("tree", -45, 0)
	advance(6)
	local shell_passed = passed.alive and passed.health == passed.max_health
	local shelled_hurt = harness.damage_to(shelled)

	-- nothing picks a rock or a tree to shoot at
	local idle = unkillable(spawn("grunt", OWN, 120, 0))
	local rock = lay("rock", 124, 0)
	local tree = lay("tree", 118, 4)
	advance(3)
	local left_alone = rock.health == rock.max_health and tree.health == tree.max_health and idle.damage_dealt == 0

	return {
		tree_health = tree_health,
		blast_destroyed = blast_destroyed,
		beam_hit = beam_hit,
		shielded_hurt = shielded_hurt,
		shell_passed = shell_passed,
		shelled_hurt = shelled_hurt,
		left_alone = left_alone,
		pass = tree_health == 250 and blast_destroyed and beam_hit and shell_passed and shelled_hurt > 0 and left_alone,
	}
end

-- What reclaiming shows as the reclaimer's own income (`reclaim`, `flows`): a Construction Bot reclaims a rock, a
-- grunt's wreck and a grunt of its own, and for each, the highest and the average metal and energy rate its infobox
-- read while it worked against what the team actually banked, which should agree. Then a wreck reclaimed into a full
-- metal store, which banks nothing and should read as stalled on storage.
local function reclaim_income(_args: Args): Findings
	local team = harness.ensure_team(OWN)
	local builder = unkillable(spawn("construction_bot", OWN, 0, 0))

	local function reclaim_watching(target: Entity, full: boolean): Findings
		advance(tick_rate.TICK_DELTA)
		harness.set_bank(OWN, { metal = if full then team.metal_capacity else 0, energy = 0 })
		local started = now()
		local peak_metal, peak_energy, total_metal, total_energy, ticks, stalled = 0, 0, 0, 0, 0, 0
		orders.issue(builder, { { kind = "reclaim", position = nil, target_id = target.id } }, false, false)
		until_idle(builder, 60, function()
			local flow = flow_of(builder.id)
			if flow == nil then
				return
			end
			ticks += 1
			peak_metal = math.max(peak_metal, flow.metal)
			peak_energy = math.max(peak_energy, flow.energy)
			total_metal += flow.metal * tick_rate.TICK_DELTA
			total_energy += flow.energy * tick_rate.TICK_DELTA
			if flow.stall == "storage" then
				stalled += 1
			end
		end)
		local seconds = now() - started
		local banked_metal = team.metal - team.metal_income * seconds
		local banked_energy = team.energy - team.energy_income * seconds
		return {
			gone = target.alive == false,
			seconds = round(seconds, 2),
			peak_rate = { metal = round(peak_metal, 1), energy = round(peak_energy, 1) },
			shown_total = { metal = round(total_metal, 1), energy = round(total_energy, 1) },
			banked = if full then nil else { metal = round(banked_metal, 1), energy = round(banked_energy, 1) },
			ticks_with_flow = ticks,
			ticks_stalled_on_storage = stalled,
			ok = target.alive == false and ticks > 0 and if full
				then stalled > 0
				else near(total_metal, banked_metal, RECLAIM_SLACK) and near(
					total_energy,
					banked_energy,
					RECLAIM_SLACK
				),
		}
	end

	local findings: Findings = {
		rock = reclaim_watching(lay("large_rock", 6, 0), false),
		wreck = reclaim_watching(harness.wreck_of("grunt", -6, 0), false),
		standing = reclaim_watching(spawn("grunt", OWN, 0, 6), false),
		wreck_into_full_store = reclaim_watching(harness.wreck_of("grunt", 0, -6), true),
	}
	findings.pass = findings.rock.ok
		and findings.wreck.ok
		and findings.standing.ok
		and findings.wreck_into_full_store.ok
	return findings
end

-- Geothermal vents and what stands on them (`spots`, `placement`, `construction`, `drones`), on a map that has
-- vents (koth unless another `preset` is given). Where the map's vents are, and how far each is from the nearest start.
-- With nocost on: a Construction Bot, or `args.unit`, puts a Geothermal Powerplant on the first vent, which should add
-- to the team's energy income; one cannot go anywhere off a vent; an Advanced Construction Bot puts an Advanced
-- Geothermal Powerplant over it, which should take the plain one's place. Then a Rampart on the second vent: its drones
-- come out as they are built, and it shoots down a nuke launched at something beside it.
local function geothermal(args: Args): Findings
	local vents = spots.all "geo"
	local where: { string } = {}
	for _, vent in vents do
		local nearest_start = math.huge
		for slot = 1, starts.count() do
			nearest_start =
				math.min(nearest_start, (starts.center(slot) - Vector2.new(vent.position.X, vent.position.Z)).Magnitude)
		end
		table.insert(
			where,
			`{math.round(vent.position.X)},{math.round(vent.position.Z)} ({math.round(nearest_start)} from a start)`
		)
	end
	assert(#vents >= 2, "this map has fewer than two geothermal vents: run it on one with more")
	local findings: Findings = { vents = #vents, where = where }
	local team = harness.ensure_team(OWN)

	-- builds `def_name` on the vent nearest (x, z) with a fresh `unit`, and returns what went up, if anything
	local function build_on(unit: string, def_name: string, x: number, z: number): (Entity?, Vector3?)
		local builder = spawn(unit, OWN, x + 14, z + 14)
		advance(tick_rate.TICK_DELTA)
		local site = placement.resolve_center(def_name, x, z, 0, builder)
		if site == nil then
			return nil, nil
		end
		orders.issue(
			builder,
			{ { kind = "build", position = site, target_id = nil, def_name = def_name, facing = 0 } },
			false,
			false
		)
		until_idle(builder, 60)
		deaths.destroy(builder, "removed")
		return finished(def_name, OWN), site
	end

	local vent = vents[1].position
	with_switch(NOCOST, true, function()
		advance(tick_rate.TICK_DELTA)
		local income_before = team.energy_income
		local plant, site = build_on(args.unit or "construction_bot", "geothermal_powerplant", vent.X, vent.Z)
		advance(tick_rate.TICK_DELTA)
		findings.plant_built = plant ~= nil
		findings.plant_on_vent = site ~= nil and spots.on_spot("geo", site)
		findings.plant_income = team.energy_income - income_before

		local off_vent = heightmap.ground_position(vent.X + 60, vent.Z + 60)
		local ok, reason = placement.can_place("geothermal_powerplant", off_vent, 0, nil, nil)
		findings.off_vent = { ok = ok, reason = reason }

		income_before = team.energy_income
		local advanced = build_on("advanced_construction_bot", "advanced_geothermal_powerplant", vent.X, vent.Z)
		advance(tick_rate.TICK_DELTA)
		findings.advanced_built = advanced ~= nil
		findings.plain_taken_down = plant ~= nil and plant.alive == false
		findings.advanced_income_change = team.energy_income - income_before
	end)

	-- a Rampart on the second vent, with an interceptor ready, and a nuke launched at a grunt beside it
	local other = vents[2].position
	local rampart_def = unit_defs.get "rampart"
	local rampart_at = placement.resolve_center("rampart", other.X, other.Z, 0, nil) :: Vector3
	local rampart = unkillable(state.create_entity("rampart", OWN, rampart_at, 0, "active"))
	advance(1)
	local function drones_out(): number
		local count = 0
		for _, entity in state.all() do
			if entity.alive and entity.def_name == "heavy_drone" and entity.team == OWN then
				count += 1
			end
		end
		return count
	end
	findings.drones_at_start = drones_out()
	with_switch(NOCOST, true, function()
		advance((rampart_def.carrier :: types.Carrier).stockpile.build_time + 1)
	end)
	findings.drones_after_build_time = drones_out()

	rampart.weapon_stockpiles[1].held = 1
	local mark = unkillable(spawn("grunt", OWN, rampart_at.X + 20, rampart_at.Z))
	-- the silo's side needs a team of its own to launch from
	harness.ensure_team(ENEMY)
	local silo_def = unit_defs.get "apocalypse"
	-- a quarter of a turn at a time round the Rampart, 250 studs out, until it is on dry land: a silo under the water
	-- launches nothing
	local silo_x, silo_z = rampart_at.X, rampart_at.Z
	for step = 0, 15 do
		local angle = math.atan2(-rampart_at.Z, -rampart_at.X) + step * math.pi / 8
		silo_x = rampart_at.X + math.cos(angle) * 250
		silo_z = rampart_at.Z + math.sin(angle) * 250
		if
			heightmap.in_bounds(silo_x, silo_z)
			and heightmap.height_at(silo_x, silo_z) > ground_levels.WATER_LEVEL + 2
		then
			break
		end
	end
	local silo = unkillable(
		state.create_entity(
			"apocalypse",
			ENEMY,
			surface.position(silo_def, silo_x, silo_z) + Vector3.new(0, unit_defs.collider_height(silo_def) / 2, 0),
			0,
			"active"
		)
	)
	advance(tick_rate.TICK_DELTA)
	silo.weapon_stockpiles[1].held = 1
	-- launched (`Order.launch`) at the ground under the grunt, as a nuke usually is, since the silo's side cannot see
	-- that far
	orders.issue(
		silo,
		{ { kind = "attack_ground", position = mark.position, target_id = nil, launch = true } },
		false,
		false
	)
	local launched = false
	local intercepted = false
	local mark_hurt = false
	advance(args.seconds or 40, function()
		if silo.weapon_stockpiles[1].held == 0 then
			launched = true
		end
		if rampart.weapon_stockpiles[1].held == 0 then
			intercepted = true
		end
		if mark.health < UNKILLABLE then
			mark_hurt = true
		end
	end)
	findings.silo = {
		alive = silo.alive,
		orders = #silo.orders,
		held = silo.weapon_stockpiles[1].held,
		at = `{math.round(silo.position.X)},{math.round(silo.position.Y)},{math.round(silo.position.Z)}`,
	}
	findings.nuke_launched = launched
	findings.interceptor_fired = intercepted
	findings.nuke_landed = mark_hurt
	findings.pass = findings.plant_built
		and findings.plant_on_vent
		and findings.plant_income > 0
		and findings.off_vent.ok == false
		and findings.advanced_built
		and findings.plain_taken_down
		and findings.advanced_income_change > 0
		and findings.drones_after_build_time > findings.drones_at_start
		and launched
		and intercepted
		and mark_hurt == false
	return findings
end

-- Rezbots repair what they raise (resurrection.luau): a guard's wreck (a building) and a grunt's (a unit), each raised
-- by two graverobbers, the team's stores kept full. The first rezbot on each has a move queued after its resurrect
-- order (shift), the second nothing. The tick the thing comes back it should be at
-- resurrection.RESURRECT_HEALTH_FRACTION of its health (`raised_at`), and both its rezbots should be on a repair order
-- on it (`repair_orders` 2), the first still with its move queued behind that (`queue_kept`). Once they are done it
-- should be whole (`whole`), the first rezbot having gone on to where its move sent it (`went_on`), within
-- `args.seconds` (60).
local function rez_repair(args: Args): Findings
	local seconds = args.seconds or 60
	harness.ensure_team(OWN)
	local function top_up()
		harness.fill_bank(OWN)
	end

	local function case(def_name: string, z: number): Findings
		local wreck = harness.wreck_of(def_name, 0, z)
		local first = spawn("graverobber", OWN, -8, z - 3)
		local second = spawn("graverobber", OWN, -8, z + 3)
		local away = heightmap.ground_position(-30, z)
		local raise_it: types.Order = { kind = "resurrect", position = nil, target_id = wreck.id }
		orders.issue(first, { raise_it, { kind = "move", position = away, target_id = nil } }, false, false)
		orders.issue(second, { table.clone(raise_it) }, false, false)
		advance(tick_rate.TICK_DELTA)

		local raised: Entity? = nil
		local raised_at: number? = nil
		local repair_orders = 0
		local queue_kept = false
		local deadline = now() + seconds
		while raised == nil and now() < deadline do
			advance(tick_rate.TICK_DELTA, top_up)
			if wreck.alive then
				continue
			end
			-- it joined the main table as the step that raised it ended
			for _, entity in state.all() do
				if entity.alive and entity.team == OWN and entity.def_name == def_name then
					raised = entity
				end
			end
		end
		if raised ~= nil then
			-- the orders ran before it came back, so nothing has been repaired yet
			raised_at = round(raised.health / raised.max_health, 2)
			for _, rezzer in { first, second } do
				local order = rezzer.orders[1]
				if order ~= nil and order.kind == "repair" and order.target_id == raised.id then
					repair_orders += 1
				end
			end
			local next_order = first.orders[2]
			queue_kept = next_order ~= nil and next_order.kind == "move"
			while now() < deadline and (#first.orders > 0 or #second.orders > 0) do
				advance(tick_rate.TICK_DELTA, top_up)
			end
		end
		local went_on = Vector2.new(first.position.X - away.X, first.position.Z - away.Z).Magnitude < 4
		local whole = raised ~= nil and raised.alive and raised.health >= raised.max_health - 0.01
		return {
			raised = raised ~= nil,
			raised_at = raised_at,
			repair_orders = repair_orders,
			queue_kept = queue_kept,
			whole = whole,
			went_on = went_on,
			pass = raised ~= nil
				and raised_at ~= nil
				and math.abs(raised_at - resurrection.RESURRECT_HEALTH_FRACTION) < 0.02
				and repair_orders == 2
				and queue_kept
				and whole
				and went_on,
		}
	end

	local building = case("guard", -20)
	local unit = case("grunt", 20)
	return {
		building = building,
		unit = unit,
		pass = building.pass == true and unit.pass == true,
	}
end

-- The build keys (shared/build_hotkeys.luau), which the key handler and the build menu both read: every building in a
-- category is one there is, it is in no other category, and no key of the default keybind profile picks two things in
-- one category. What a category's
-- own key places for a commander is its main building while that is unlocked; with the main building locked it is the
-- first unlocked building in the category the commander can build, and the menu still shows the main building, locked.
local function build_hotkeys_data(_args: Args): Findings
	local unknown: { string } = {}
	local in_two: { string } = {}
	local repeated_keys: { string } = {}
	local seen: { [string]: string } = {}
	local bindings = keybinds.resolve(keybinds.fresh())
	for _, category in build_hotkeys.categories do
		local keys: { [string]: boolean } = {}
		for _, pick in category.picks do
			local key = bindings[pick.action]
			if keys[key] then
				table.insert(repeated_keys, `{category.name} {key}`)
			end
			keys[key] = true
		end
		for _, def_name in category.defs do
			local def = unit_defs.defs[def_name]
			if def == nil or def.kind ~= "building" then
				table.insert(unknown, def_name)
			end
			if seen[def_name] ~= nil and seen[def_name] ~= category.name then
				table.insert(in_two, def_name)
			end
			seen[def_name] = category.name
		end
	end

	-- every lab's every unit has a key slot there, and the lab slots name only what the lab makes
	local lab_keys_missing: { string } = {}
	for name, def in unit_defs.defs do
		if unit_defs.is_factory(def) == false then
			continue
		end
		for _, unit in unit_defs.build_options(def) do
			if build_hotkeys.lab_action(name, unit) == nil then
				table.insert(lab_keys_missing, `{name}: {unit}`)
			end
		end
	end
	for lab, units in build_hotkeys.labs do
		local def = unit_defs.defs[lab]
		for unit in units do
			if def == nil or table.find(unit_defs.build_options(def), unit) == nil then
				table.insert(lab_keys_missing, `{lab} has no {unit}`)
			end
		end
	end

	local economy = build_hotkeys.started_by "build_economy" :: build_hotkeys.Category
	local builds = unit_defs.build_options(unit_defs.get "commander")
	local all_unlocked = build_hotkeys.entry(economy, builds, function(_: string): boolean
		return true
	end)
	local main = economy.picks[1].defs
	local locked_entry, locked_shown = build_hotkeys.entry(economy, builds, function(def_name: string): boolean
		return table.find(main, def_name) == nil
	end)
	local expected_locked: string? = nil
	for _, def_name in economy.defs do
		if table.find(main, def_name) == nil and table.find(builds, def_name) ~= nil then
			expected_locked = def_name
			break
		end
	end

	local findings: Findings = {
		unknown = table.concat(unknown, ", "),
		in_two_categories = table.concat(in_two, ", "),
		repeated_keys = table.concat(repeated_keys, ", "),
		lab_keys_missing = table.concat(lab_keys_missing, ", "),
		economy_entry = all_unlocked,
		entry_with_main_locked = locked_entry,
		shown_with_main_locked = locked_shown,
	}
	findings.pass = #unknown == 0
		and #in_two == 0
		and #repeated_keys == 0
		and #lab_keys_missing == 0
		and all_unlocked == "metal_extractor"
		and locked_entry == expected_locked
		and locked_entry ~= nil
		and locked_shown == locked_entry
		and build_hotkeys.entry(economy, builds, function(_: string): boolean
			return false
		end) == nil
		and select(
				2,
				build_hotkeys.entry(economy, builds, function(_: string): boolean
					return false
				end)
			)
			== "metal_extractor"
	return findings
end

-- The keybinds (shared/keybinds.luau): in every profile no two actions that share a scope share a key; binding a key
-- unbinds only what shares a scope with the action it goes to, and binding it back puts the profile's key back with
-- nothing left rebound; a record read from anything keeps only what a record can hold; and a tip's key is filled in.
local function keybinds_data(_args: Args): Findings
	local clashes: { string } = {}
	for _, profile in keybinds.profiles do
		local bindings = keybinds.resolve({ profile = profile.id, custom = {} })
		for index, each in keybinds.actions do
			for other_index = index + 1, #keybinds.actions do
				local other = keybinds.actions[other_index]
				local binding = bindings[each.id]
				if binding == "" or bindings[other.id] ~= binding then
					continue
				end
				for _, scope in each.scopes do
					if table.find(other.scopes, scope) ~= nil then
						table.insert(clashes, `{profile.id}: {each.id} and {other.id} on {binding}`)
						break
					end
				end
			end
		end
	end

	local fresh = keybinds.fresh()
	local default = keybinds.DEFAULT_PROFILE
	local fresh_bindings = keybinds.resolve(fresh)
	-- G stops; given to Attack it unbinds Stop, but not the Mount a piloted unit calls with G
	local moved, unbound = keybinds.bind(fresh, "mode_attack", "G")
	local moved_bindings = keybinds.resolve(moved)
	local back = keybinds.bind(keybinds.bind(moved, "mode_attack", fresh_bindings.mode_attack), "stop", "G")
	local decoded = keybinds.decode({
		profile = "nonsense",
		custom = { [default] = { stop = "Ctrl+H", camera_up = "Ctrl+W", nothing = "A", select_same = "Escape" } },
	})
	local decoded_bindings = keybinds.resolve(decoded)

	local findings: Findings = {
		clashes = table.concat(clashes, "; "),
		unbound = table.concat(unbound, ", "),
		pilot_call_kept = moved_bindings.pilot_call,
		back_to_profile = keybinds.same(back, fresh),
		decoded_stop = decoded_bindings.stop,
		decoded_camera_up = decoded_bindings.camera_up,
		decoded_select_same = decoded_bindings.select_same,
		filled = keybinds.fill("Press {key:shield}, {key:self_destruct}", keybinds.resolve(fresh)),
	}
	findings.pass = #clashes == 0
		and #unbound == 1
		and unbound[1] == "stop"
		and moved_bindings.stop == ""
		and moved_bindings.mode_attack == "G"
		and moved_bindings.pilot_call == "G"
		and back.custom[default] ~= nil
		and next(back.custom[default]) == nil
		and findings.back_to_profile == true
		and decoded.profile == default
		and decoded_bindings.stop == "Ctrl+H"
		-- a held action takes no ctrl, and Escape is never bound
		and decoded_bindings.camera_up == fresh_bindings.camera_up
		and decoded_bindings.select_same == "Q"
		and findings.filled == "Press K, Ctrl+B"
	return findings
end

-- What `construction.can_repair` rules out, for every way a builder repairs: a Construction Bot takes apart a damaged
-- Solar Collector of its own side while another is ordered to repair it. There is no point mending what an ally is
-- reclaiming, so the repair order should be dropped rather than fight the reclaim, and the collector should not gain
-- health from it.
local function repair_while_reclaimed(_args: Args): Findings
	local findings: Findings = {}
	with_switch(NOCOST, true, function()
		local solar = spawn("solar_collector", OWN, 20, 0)
		solar.health = solar.max_health / 2
		local reclaimer = unkillable(spawn("construction_bot", OWN, 20, 12))
		local mender = unkillable(spawn("construction_bot", OWN, 20, -12))
		advance(tick_rate.TICK_DELTA)
		orders.issue(reclaimer, { { kind = "reclaim", position = nil, target_id = solar.id } }, false, false)
		advance(tick_rate.TICK_DELTA * 3)
		local health_before = solar.health
		orders.issue(mender, { { kind = "repair", position = nil, target_id = solar.id } }, false, false)
		advance(1)
		findings = {
			can_repair = construction.can_repair(mender, solar),
			repair_dropped = #mender.orders == 0,
			healed = solar.alive and solar.health > health_before,
		}
		findings.pass = findings.can_repair == false and findings.repair_dropped and findings.healed == false
	end)
	return findings
end

-- The order queue as it is published for the clients (shared/order_path): what a move, a build, a launch and an area
-- order are encoded as, and whether decoding that gives each back as it was, to the whole stud, and the last step
-- where the queue ends.
local function order_path_codec(_args: Args): Findings
	local target = spawn("grunt", ENEMY, 40, 40)
	local queue: { types.Order } = {
		{ kind = "move", position = Vector3.new(10.4, 3, -20.6) },
		{ kind = "build", position = Vector3.new(32, 0, 48), def_name = "solar_collector", facing = math.pi / 2 },
		{ kind = "attack", target_id = target.id, launch = true },
		{ kind = "area_reclaim", position = Vector3.new(-5, 0, 5), radius = 30.2 },
	}
	local text = order_path.encode(queue, function(order: types.Order): Vector3?
		if order.position ~= nil then
			return order.position
		end
		return if order.target_id == target.id then target.position else nil
	end)
	local steps = order_path.decode(text)
	local last = order_path.last(text)
	local findings: Findings = { text = text, steps = #steps }
	findings.pass = #steps == 4
		and steps[1].kind == "move"
		and steps[1].x == 10
		and steps[1].z == -21
		and steps[2].def_name == "solar_collector"
		and steps[2].target_id == nil
		and steps[2].facing ~= nil
		and math.abs((steps[2].facing :: number) - math.pi / 2) < 0.01
		and steps[3].target_id == target.id
		and steps[3].launch
		and steps[3].def_name == nil
		and steps[4].radius == 30
		and steps[4].launch == false
		and last ~= nil
		and last.kind == "area_reclaim"
		and #order_path.decode "" == 0
	return findings
end

local TESTS: { [string]: Test } = {
	repair_while_reclaimed = { run = repair_while_reclaimed },
	order_path_codec = { run = order_path_codec },
	build_hotkeys = { run = build_hotkeys_data },
	keybinds = { run = keybinds_data },
	build_route = { run = build_route },
	build_in_reach = { run = build_in_reach, defaults = { preset = "koth" } },
	build_reach_edge = { run = build_reach_edge },
	builder_blocked = { run = builder_blocked },
	mex_queue_snap = { run = mex_queue_snap },
	reclaimables = { run = reclaimables, defaults = { scenery = true } },
	reclaimables_harmed = { run = reclaimables_harmed },
	reclaim_income = { run = reclaim_income },
	geothermal = { run = geothermal, defaults = { preset = "koth" } },
	rez_repair = { run = rez_repair },
}

return table.freeze(TESTS)
