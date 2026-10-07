--!strict
-- What a brain's builders and rezbots are sent to do. With only a commander it opens (`open`): the profile's
-- opening_extractors metal extractors on the spots nearest home, its opening_energy wind turbines, and then a lab of
-- its line. After that each builder with nothing to do is given what the economy planner wants built, or else something
-- to help with (`assist`); a builder out on the map that is caught where the enemy reaches, or is being hit, runs for
-- home (`flee`), and one whose errand turns dangerous on the way drops it, as it does a build it can no longer do
-- (`give_up_lost_build`). Rezbots raise the wrecks lying somewhere quiet (`run_rezbots`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local teams = require(ReplicatedStorage.Shared.teams)

local state = require(ServerScriptService.Server.state)
local orders = require(ServerScriptService.Server.orders)
local placement = require(ServerScriptService.Server.placement)
local reclaim = require(ServerScriptService.Server.reclaim)
local resurrection = require(ServerScriptService.Server.resurrection)
local damage = require(ServerScriptService.Server.damage)
local manual_weapons = require(ServerScriptService.Server.manual_weapons)
local alliances = require(ServerScriptService.Server.alliances)

local danger_field = require(script.Parent.danger_field)
local brains = require(script.Parent.brains)
local assignments = require(script.Parent.assignments)
local catalog = require(script.Parent.catalog)
local censuses = require(script.Parent.census)
local siting = require(script.Parent.siting)
local routes = require(script.Parent.routes)
local economy_planner = require(script.Parent.economy_planner)

type Entity = types.Entity
type EntityId = types.EntityId
type Order = types.Order
type OrderKind = types.OrderKind
type Brain = brains.Brain
type Line = brains.Line
type Census = censuses.Census
type Economy = censuses.Economy
type Task = siting.Task

-- How long a builder that was given something to help with is left at it before it is looked at again.
local ASSIST_RECHECK = 6
-- A builder or a rezbot sent to work stops this share of its reach short of where the work is, to be well in reach.
local WORK_REACH_SHARE = 0.8
-- A builder with nothing better to do helps with what is within this many times the profile's base_radius of it, and
-- a rezbot with no wrecks about reclaims what is as near home.
local HELP_RADIUS_SHARE = 2
-- A builder at its site with something there it cannot clear away (anything but a wreck or a unit of its own) gives up
-- on it after BLOCKED_GRACE seconds, and the site is not built on again for BAD_SITE_SECONDS; the game itself would keep
-- it standing there for a good while first (orders.luau's BUILD_STUCK_SECONDS). It is at its site within its build
-- range and the building's half size, and SITE_SLACK.
local BLOCKED_GRACE = 2
local BAD_SITE_SECONDS = 60
local SITE_SLACK = 2

-- How far from its work `unit` stops.
local function work_reach(unit: Entity): number
	return (unit_defs.build_range(unit.def) or 0) * WORK_REACH_SHARE
end

-- How far round a builder, or home, a builder with nothing better to do looks for something to help with.
local function help_radius(brain: Brain): number
	return brain.profile.base_radius * HELP_RADIUS_SHARE
end

-- The order that puts up `task`.
local function build_order(task: Task): Order
	return {
		kind = "build",
		position = task.position,
		target_id = nil,
		def_name = task.def_name,
		facing = task.facing,
	}
end

-- Sends `builder` to put up `task`. Returns whether it went.
local function send_to_build(brain: Brain, census: Census, builder: Entity, task: Task): boolean
	local chain = routes.waypoints(brain, builder, task.position, work_reach(builder))
	if
		chain == nil
		or (#chain > 0 and routes.chain_danger(brain, builder, chain, task.position) >= brain.profile.safe_danger)
	then
		return false
	end
	table.insert(chain, build_order(task))
	orders.issue(builder, chain, false, false)
	censuses.add_plan(census, task.def_name, task.position, task.facing)
	assignments.release_from(brain, builder.id, "assist")
	if
		censuses.duty_of(census, builder).ventures
		and geometry.distance_2d(task.position, brain.home) > brain.profile.base_radius
	then
		assignments.assign(brain, builder.id, { job = "expand" })
	end
	return true
end

-- With only a commander: extractors on the spots nearest home, wind turbines, and then a lab, all in one queue. What
-- its profile's roster leaves out is left out.
local function open(brain: Brain, census: Census, commander: Entity)
	brain.opened = true
	local chain: { Order } = {}
	local function plan(task: Task?)
		if task == nil then
			return
		end
		table.insert(chain, build_order(task))
		censuses.add_plan(census, task.def_name, task.position, task.facing)
	end
	for _ = 1, brain.profile.opening_extractors do
		plan(economy_planner.extractor_task(brain, census, commander, brain.profile.base_radius))
	end
	-- the cheapest of the commander's energy (wind turbines) it may build
	local energy: string? = nil
	for _, def_name in catalog.ENERGY_TIERS[1] do
		if brains.can_build(commander, def_name) then
			energy = def_name
			break
		end
	end
	if energy ~= nil then
		for _ = 1, brain.profile.opening_energy do
			plan(siting.cluster_site(brain, census, energy))
		end
	end
	local line: Line = economy_planner.resolve_line(brain, census)
	plan(economy_planner.lab_task(brain, census, commander, catalog.LABS[line].first, 1))
	if #chain > 0 then
		orders.issue(commander, chain, false, false)
	end
end

-- Whether `builder` has nothing to do that the AI would not take it off: no orders, or help it was given for want of
-- anything better and has been at a while.
local function is_available(brain: Brain, builder: Entity): boolean
	local now = brains.now()
	local assignment = assignments.get(brain, builder.id)
	if assignment ~= nil and assignment.job == "flee" then
		if now < assignment.ends_at then
			return false
		end
		assignments.release(brain, builder.id)
	end
	if #builder.orders == 0 then
		assignments.release_from(brain, builder.id, "assist")
		return true
	end
	return assignment ~= nil and assignment.job == "assist" and now >= assignment.ends_at
end

-- A hurt fighter of its own that came home to be mended where there is no construction turret to do it, the nearest
-- `builder`, if it can repair and there is one near it by a quiet way.
local function to_mend(brain: Brain, builder: Entity): Entity?
	if unit_defs.does(builder.def, "repair") ~= true then
		return nil
	end
	local best: Entity? = nil
	local best_distance = help_radius(brain)
	for _, unit_id in assignments.each(brain, "retreat") do
		local unit = state.get(unit_id)
		local assignment = assignments.get(brain, unit_id)
		local waiting = assignment ~= nil
			and assignment.job == "retreat"
			and assignment.retreat.arrived
			and assignment.retreat.turret == nil
		if unit == nil or waiting == false then
			continue
		end
		local distance = geometry.distance_2d(unit.position, builder.position)
		if
			distance < best_distance
			and routes.route_danger(brain, builder.position, unit.position) < brain.profile.safe_danger
		then
			best = unit
			best_distance = distance
		end
	end
	return best
end

-- The lab of its own nearest `builder`, within `within` of it, that is making something.
local function busy_lab_near(census: Census, builder: Entity, within: number): Entity?
	local lab: Entity? = nil
	local nearest = math.huge
	for _, factory in census.factories do
		local distance = geometry.distance_2d(factory.position, builder.position)
		if #factory.queue > 0 and distance < nearest and distance <= within then
			lab = factory
			nearest = distance
		end
	end
	return lab
end

-- Gives `unit` `order`, unless it is at it already.
local function keep_at(unit: Entity, order: Order)
	local current = unit.orders[1]
	if current == nil or current.kind ~= order.kind or current.target_id ~= order.target_id then
		orders.issue(unit, { order }, false, false)
	end
end

-- Something for a builder with nothing better to do to help with: a hurt fighter come home to be mended (see
-- retreats.luau), the dearest unfinished building of its own near it, somewhere quiet, or else a lab of its own that
-- is making something, which it guards and so helps.
local function assist(brain: Brain, census: Census, builder: Entity)
	local base_radius = brain.profile.base_radius
	local mend = to_mend(brain, builder)
	if mend ~= nil then
		keep_at(builder, { kind = "repair", position = nil, target_id = mend.id })
		assignments.assign(brain, builder.id, { job = "assist", ends_at = brains.now() + ASSIST_RECHECK })
		return
	end
	local best: Entity? = nil
	local best_worth = 0
	for _, building in census.structures do
		if
			building.state ~= "blueprint"
			or geometry.distance_2d(building.position, builder.position) > help_radius(brain)
		then
			continue
		end
		local worth = unit_defs.power(building.def)
		if
			worth > best_worth
			and routes.route_danger(brain, builder.position, building.position) < brain.profile.safe_danger
		then
			best = building
			best_worth = worth
		end
	end
	local order: Order? = nil
	if best ~= nil then
		order = { kind = "assist", position = nil, target_id = best.id }
	else
		local lab = busy_lab_near(census, builder, math.huge)
		if lab ~= nil then
			order = { kind = "guard", position = nil, target_id = lab.id }
		end
	end
	if order == nil then
		-- nothing at all: a builder out on the map comes home
		if geometry.distance_2d(builder.position, brain.home) > base_radius and #builder.orders == 0 then
			local chain = routes.waypoints(brain, builder, brain.home, base_radius / 2)
			if chain ~= nil then
				table.insert(chain, { kind = "move", position = brain.home })
				orders.issue(builder, chain, false, false)
			end
		end
		return
	end
	keep_at(builder, order)
	assignments.assign(brain, builder.id, { job = "assist", ends_at = brains.now() + ASSIST_RECHECK })
end

-- A builder out beyond the base that is caught somewhere the enemy reaches, or is being hit, drops what it was doing
-- and runs for home; one that keeps to the base (census.luau's `Duty`) never does.
local function flee(brain: Brain, census: Census, builder: Entity, hurt: boolean): boolean
	local profile = brain.profile
	if
		censuses.duty_of(census, builder).ventures == false
		or geometry.distance_2d(builder.position, brain.home) <= profile.base_radius
	then
		return false
	end
	if hurt == false and danger_field.at(brain.field, builder.position) < profile.flee_danger then
		return false
	end
	local chain = routes.waypoints(brain, builder, brain.home, profile.base_radius / 2) or {}
	table.insert(chain, { kind = "move", position = brain.home })
	orders.issue(builder, chain, false, false)
	-- whatever errand it was on is dropped
	assignments.release_from(brain, builder.id, "expand")
	assignments.release_from(brain, builder.id, "assist")
	assignments.assign(brain, builder.id, { job = "flee", ends_at = brains.now() + profile.flee_seconds })
	return true
end

-- Where `builder`'s orders take it before it gets to work, as the moves on the way and where the work is; nil when
-- it has nothing to go to, or is guarding something, which it keeps beside.
local function errand_of(builder: Entity): ({ Order }, Vector3?)
	local moves: { Order } = {}
	for _, order in builder.orders do
		if order.kind == "move" then
			table.insert(moves, order)
			continue
		end
		if order.kind == "build" then
			return moves, order.position
		end
		if order.kind == "assist" or order.kind == "repair" or order.kind == "reclaim" then
			local target = if order.target_id ~= nil then state.get(order.target_id) else nil
			return moves, if target ~= nil then target.position else order.position
		end
		return moves, nil
	end
	local last = moves[#moves]
	return moves, if last ~= nil then last.position else nil
end

-- Whether what `builder` is on its way to do has turned dangerous, where the work is or on the way there.
local function errand_dangerous(brain: Brain, builder: Entity): boolean
	local moves, goal = errand_of(builder)
	if goal == nil then
		return false
	end
	-- the moves already behind it are dropped from its orders, so this is only the way it has left to go
	local abort = brain.profile.abort_danger
	return danger_field.at(brain.field, goal) >= abort or routes.chain_danger(brain, builder, moves, goal) >= abort
end

-- The commander helps a lab of its own that is making something, while the team has fewer constructors than the
-- profile's commander_assist_constructors and is short of neither energy nor metal, so that the first constructors
-- come out sooner (BARb's commander.json "assist_fac"). Returns whether it does.
local function help_lab(brain: Brain, census: Census, economy: Economy, commander: Entity): boolean
	local wanted = brain.profile.commander_assist_constructors
	if wanted <= 0 or #census.builders - 1 >= wanted or economy.energy_stalling or economy.metal_short then
		return false
	end
	local lab = busy_lab_near(census, commander, brain.profile.base_radius)
	if lab == nil then
		return false
	end
	keep_at(commander, { kind = "guard", position = nil, target_id = lab.id })
	assignments.assign(brain, commander.id, { job = "assist", ends_at = brains.now() + ASSIST_RECHECK })
	return true
end

-- A build `builder` was sent to that it can no longer do is given up at once, rather than walked to and stood at: an
-- extractor on a spot another team has put one on since (while it walked there), or a site it has reached with
-- something on it that it cannot clear away (BLOCKED_GRACE), which is then left alone for BAD_SITE_SECONDS. The rest of
-- its orders stand.
local function give_up_lost_build(brain: Brain, census: Census, builder: Entity)
	local pending_at: number? = nil
	for index, order in builder.orders do
		if order.kind ~= "move" then
			pending_at = if order.kind == "build" then index else nil
			break
		end
	end
	local pending = if pending_at ~= nil then builder.orders[pending_at] else nil
	local position = if pending ~= nil then pending.position else nil
	local def_name = if pending ~= nil then pending.def_name else nil
	if pending == nil or pending_at == nil or position == nil or def_name == nil then
		brain.blocked[builder.id] = nil
		return
	end
	local now = brains.now()
	local lost = false
	if catalog.role_of(def_name).extractor then
		lost = censuses.nearest_distance(census.foreign_spots, position) < siting.SAME_SPOT
	end
	local half = unit_defs.footprint_half_extents(unit_defs.get(def_name))
	local reach = (unit_defs.build_range(builder.def) or 0) + math.max(half.X, half.Y) + SITE_SLACK
	if lost == false and pending_at == 1 and geometry.distance_2d(builder.position, position) <= reach then
		local placeable, problem = placement.can_place(def_name, position, pending.facing or 0, builder, brain.team)
		if placeable == false and problem == "blocked" then
			local since = brain.blocked[builder.id] or now
			brain.blocked[builder.id] = since
			if now - since >= BLOCKED_GRACE then
				lost = true
				table.insert(brain.bad_sites, { position = position, expires = now + BAD_SITE_SECONDS })
			end
		else
			brain.blocked[builder.id] = nil
		end
	end
	if lost then
		brain.blocked[builder.id] = nil
		assignments.release_from(brain, builder.id, "assist")
		orders.issue(builder, table.move(builder.orders, pending_at + 1, #builder.orders, 1, {}), false, false)
	end
end

-- With the profile's scrap_labs_for_advanced, while its line's advanced lab goes up every other lab it has is reclaimed
-- into it: each that nobody is taking apart yet by the nearest builder free to (its commander or a constructor), which
-- sees it through. Builders left over help the advanced lab, as `assist` has them help the biggest thing going up.
local function scrap_old_labs(brain: Brain, census: Census)
	if brain.profile.scrap_labs_for_advanced == false or brain.line == nil then
		return
	end
	local advanced = catalog.LABS[brain.line :: Line].advanced
	local going_up = false
	for _, lab in censuses.buildings_of(census, advanced) do
		if lab.state == "blueprint" then
			going_up = true
		end
	end
	if going_up == false then
		return
	end
	local taken: { [EntityId]: boolean } = {}
	for _, builder in census.builders do
		local order = builder.orders[1]
		if order ~= nil and order.kind == "reclaim" and order.target_id ~= nil then
			taken[order.target_id] = true
		end
	end
	for _, lab in census.factories do
		if lab.def_name == advanced or taken[lab.id] == true then
			continue
		end
		local best: Entity? = nil
		local best_distance = math.huge
		for _, builder in census.builders do
			if is_available(brain, builder) == false or reclaim.can_reclaim(builder, lab) == false then
				continue
			end
			local distance = geometry.distance_2d(builder.position, lab.position)
			if distance < best_distance then
				best = builder
				best_distance = distance
			end
		end
		if best == nil then
			return
		end
		local chain = routes.waypoints(brain, best, lab.position, work_reach(best)) or {}
		table.insert(chain, { kind = "reclaim", position = nil, target_id = lab.id })
		orders.issue(best, chain, false, false)
		assignments.release_from(brain, best.id, "assist")
		taken[lab.id] = true
	end
end

-- With the profile's uses_disintegrator, its commander fires its disintegrator at the enemy within its reach: at the
-- one whose shot would destroy the most of the enemy's worth, when that is at least the profile's disintegrate_worth,
-- nothing of its own or its allies' is in the way, no enemy commander blocks it, and it has the weapon ready and the
-- energy for it. The shot goes ahead of whatever the commander was doing, which it then gets back to.
local function disintegrate(brain: Brain, census: Census)
	local commander = census.commander
	if brain.profile.uses_disintegrator == false or commander == nil then
		return
	end
	local weapon = commander.def.manual_weapon
	local team = state.get_team(brain.team)
	if
		weapon == nil
		or team == nil
		or commander.manual_reload_remaining > 0
		or team.energy < weapon.energy_per_shot
		or (commander.orders[1] ~= nil and commander.orders[1].kind == "dgun")
	then
		return
	end
	local best: Vector3? = nil
	local best_worth = brain.profile.disintegrate_worth
	for _, list in { census.enemy_units, census.enemy_structures } do
		for _, enemy in list do
			if geometry.distance_2d(enemy.position, commander.position) > weapon.range then
				continue
			end
			local inside, blocked = manual_weapons.sweep(commander, enemy.position)
			if inside == nil or blocked then
				continue
			end
			local worth = 0
			local ours = false
			for _, other in inside do
				if alliances.are_allied(brain.team, other.team) then
					ours = true
					break
				end
				if other.team ~= teams.NEUTRAL then
					worth += unit_defs.power(other.def)
				end
			end
			if ours == false and worth > best_worth then
				best = enemy.position
				best_worth = worth
			end
		end
	end
	if best ~= nil then
		orders.issue(commander, { { kind = "dgun", position = best } }, false, true)
	end
end

local function run_builders(brain: Brain, census: Census, economy: Economy)
	disintegrate(brain, census)
	scrap_old_labs(brain, census)
	for _, builder in census.builders do
		local duty = censuses.duty_of(census, builder)
		if assignments.job_of(brain, builder.id) ~= "flee" then
			if flee(brain, census, builder, brain.hit[builder.id] == true) then
				continue
			end
			-- one that keeps to the base sees its errands through; it is only never sent on a dangerous one
			if duty.ventures and #builder.orders > 0 and errand_dangerous(brain, builder) then
				-- out on the map it goes home; in the base it only stops, and is given something else below
				if flee(brain, census, builder, true) == false then
					orders.issue(builder, {}, false, false)
					assignments.release_from(brain, builder.id, "assist")
				end
			end
		end
		give_up_lost_build(brain, census, builder)
		if is_available(brain, builder) == false then
			continue
		end
		assignments.release_from(brain, builder.id, "expand")
		if duty.helps_lab and help_lab(brain, census, economy, builder) then
			continue
		end
		local task = economy_planner.choose_task(brain, census, economy, builder)
		if task ~= nil and send_to_build(brain, census, builder, task) then
			continue
		end
		assist(brain, census, builder)
	end
	table.clear(brain.hit)
end

-- Rezbots raise the wrecks of units (of what it may build) that lie somewhere quiet, by a quiet way, reclaim any other
-- wreck there, and with no wrecks about reclaim the rocks and trees near home.
local function run_rezbots(brain: Brain, census: Census)
	local safe = brain.profile.safe_danger
	local claimed: { [EntityId]: boolean } = {}
	for _, rezbot_id in assignments.each(brain, "salvage") do
		local rezbot = state.get(rezbot_id)
		local assignment = assignments.get(brain, rezbot_id)
		local target_id = if assignment ~= nil and assignment.job == "salvage" then assignment.target else nil
		if rezbot == nil or #rezbot.orders == 0 or target_id == nil or state.get(target_id) == nil then
			assignments.release(brain, rezbot_id)
		else
			claimed[target_id] = true
		end
	end
	for _, rezbot in census.rezbots do
		local job = assignments.job_of(brain, rezbot.id)
		if job == "salvage" then
			continue
		end
		if #rezbot.orders > 0 and job ~= "assist" then
			continue
		end
		local best: Entity? = nil
		local best_distance = math.huge
		for _, wreck in census.wrecks do
			if claimed[wreck.id] then
				continue
			end
			if danger_field.peak_near(brain.field, wreck.position, danger_field.CELL_STUDS) >= safe then
				continue
			end
			local distance = geometry.distance_2d(rezbot.position, wreck.position)
			if distance < best_distance and routes.route_danger(brain, rezbot.position, wreck.position) < safe then
				best = wreck
				best_distance = distance
			end
		end
		if best == nil then
			for _, rock in census.reclaimables do
				if claimed[rock.id] or geometry.distance_2d(rock.position, brain.home) > help_radius(brain) then
					continue
				end
				local distance = geometry.distance_2d(rezbot.position, rock.position)
				if distance < best_distance then
					best = rock
					best_distance = distance
				end
			end
		end
		if best == nil then
			assist(brain, census, rezbot)
			continue
		end
		local found: Entity = best
		-- what its roster leaves out it does not raise either, only reclaims
		local wreck = found.wreck
		local kind: OrderKind = if found.kind == "wreck"
				and resurrection.can_resurrect(rezbot, found)
				and (wreck == nil or brains.may_build(brain.team, wreck.source_def_name))
			then "resurrect"
			else "reclaim"
		if kind == "reclaim" and reclaim.can_reclaim(rezbot, found) == false then
			continue
		end
		local chain = routes.waypoints(brain, rezbot, found.position, work_reach(rezbot))
		if chain == nil then
			continue
		end
		table.insert(chain, { kind = kind, position = found.position, target_id = found.id })
		orders.issue(rezbot, chain, false, false)
		assignments.assign(brain, rezbot.id, { job = "salvage", target = found.id })
		claimed[found.id] = true
	end
end

-- From now on a builder of a brain's that is hit is one to run for home, if it is out on the map, at the brain's next
-- thought.
local function init()
	damage.on_hurt(function(target: Entity, _amount: number)
		local brain = brains.get(target.team)
		if brain ~= nil and catalog.role_of(target.def_name).builder then
			brain.hit[target.id] = true
		end
	end)
end

return table.freeze({
	init = init,
	open = open,
	run_builders = run_builders,
	run_rezbots = run_rezbots,
})
