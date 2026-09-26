--!strict
-- What a brain's builders put up: for each builder with nothing to do, the first thing that is wanted of what it can
-- build (`choose_task`), in the order of WANTS, each with the gate that says whether it is wanted now and the task that
-- finds where it goes:
--
-- - A lab of its line, if it has none, and more up to the profile's labs as its income grows; never a second of any
--   other lab.
-- - Energy, when it is stalling: what the commander can build (wind turbines), what a constructor can build once the
--   team makes the profile's constructor_energy_income (advanced solar collectors), and what an advanced constructor
--   can build once it makes its advanced_energy_income and has one (fusion reactors); the cheapest of each.
-- - Its line's advanced lab, once it makes the profile's advanced_lab_income metal.
-- - Construction turrets beside its labs, now and then as its income grows.
-- - Metal extractors on the free spots out on the map, each builder that goes out of the base with an escort.
-- - Energy, to keep up with its metal (the profile's energy factor, `energy_per_metal`).
-- - Energy storage while its energy piles up, until it can hold the profile's storage_seconds of its income, and from
--   there energy converters to turn what piles up into metal. What they burn counts as energy it wants, so it builds
--   more energy (advanced solar collectors, then fusion) to feed them, and grows on energy once the metal spots run
-- out.
-- - A guard beside every metal extractor (the profile's extractor_guards of them), and its home_guards round home.
-- - With an advanced constructor, advanced extractors over the plain ones.
-- - Anti-air, once the enemy has the profile's air_threat_count aircraft up (its air_defense of what it would want).
--
-- With only a commander it opens instead (errands.luau's `open`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local surface = require(ReplicatedStorage.Shared.surface)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local geometry = require(ReplicatedStorage.Shared.geometry)
local pathfinder = require(ReplicatedStorage.Shared.pathfinder)
local spots = require(ReplicatedStorage.Shared.spots)

local placement = require(ServerScriptService.Server.placement)
local rng = require(ServerScriptService.Server.rng)

local danger_field = require(script.Parent.danger_field)
local brains = require(script.Parent.brains)
local catalog = require(script.Parent.catalog)
local censuses = require(script.Parent.census)
local siting = require(script.Parent.siting)
local routes = require(script.Parent.routes)

type Entity = types.Entity
type EntityDef = types.EntityDef
type Brain = brains.Brain
type Line = brains.Line
type Census = censuses.Census
type Economy = censuses.Economy
type Task = siting.Task

-- What a thing that is wanted is weighed with: the brain, what it has, and the builder that is free.
type Context = {
	brain: Brain,
	census: Census,
	economy: Economy,
	builder: Entity,
	-- how many builders it has
	builders: number,
	-- how far from home the builder takes an extractor; nil for anywhere
	reach: number?,
}

-- One thing it may want built: whether it is wanted now, and where it would go, if anywhere.
type Want = {
	name: string,
	gate: (Context) -> boolean,
	task: (Context) -> Task?,
}

-- Siting, in studs from what it is sited by.
local SITING = table.freeze({
	LAB_OFFSET = 18,
	LAB_SEARCH_RADIUS = 60,
	-- A guard goes this far from the extractor it guards, and an extractor counts as guarded with one this close.
	GUARD_RING_INNER = 6,
	GUARD_RING_OUTER = 14,
	GUARDED_RADIUS = 16,
	-- Anti-air goes this far from what it covers.
	AIR_RING_INNER = 8,
	AIR_RING_OUTER = 22,
	-- Guards round home go on rings this far out round a point this far in front of it, past the labs, and count as
	-- round home within the profile's base_radius of it.
	HOME_GUARD_OFFSET = 40,
	HOME_GUARD_RING = 30,
})
-- Of the free spots nearest, how many an extractor is tried on.
local EXTRACTOR_TRIES = 6
-- Choosing its line, it asks whether a vehicle could drive this far from home toward the middle of the map, or this
-- nearer one where that is off the map.
local LINE_PROBE = 120
local LINE_PROBE_NEAR = 40
-- What guards an extractor, and home: the cheapest defence against what walks and drives.
local GUARD = catalog.GROUND_DEFENSES[1]

-- Whether what `def_name` makes can be turned on what walks and drives: a guard, to count what guards a place.
local function hits_ground(def_name: string): boolean
	return catalog.role_of(def_name).hits_ground
end

-- How many of all of `def_names` it has, finished or not, with what it has planned.
local function count_all(census: Census, def_names: { string }): number
	local total = 0
	for _, def_name in def_names do
		total += censuses.count_of(census, def_name)
	end
	return total
end

-- How many of all of `def_names` are under way.
local function in_progress_all(census: Census, def_names: { string }): number
	local total = 0
	for _, def_name in def_names do
		total += censuses.in_progress(census, def_name)
	end
	return total
end

-- Of `def_names`, what `builder` should build: the biggest by `size` it can build of those whose size is within
-- `allowance`, or with none, the smallest of them all, if it can build that.
local function best_affordable(
	builder: Entity,
	def_names: { string },
	size: (EntityDef) -> number,
	allowance: number
): string?
	local smallest: string? = nil
	local best: string? = nil
	for _, def_name in def_names do
		local of = size(unit_defs.get(def_name))
		if smallest == nil or of < size(unit_defs.get(smallest :: string)) then
			smallest = def_name
		end
		if
			of <= allowance
			and brains.can_build(builder, def_name)
			and (best == nil or of > size(unit_defs.get(best :: string)))
		then
			best = def_name
		end
	end
	if best == nil and smallest ~= nil and brains.can_build(builder, smallest) then
		return smallest
	end
	return best
end

-- The best free, quiet metal spot for `builder` to put an extractor on, by a quiet way, within `max_distance` of home
-- if that is given: near the builder and home, and rich ones first. Not one another team's builder nearer it is on its
-- way to, which would get there first, nor one its own builders gave up on (siting.given_up).
local function extractor_task(brain: Brain, census: Census, builder: Entity, max_distance: number?): Task?
	local def_name = catalog.PLAIN_EXTRACTOR
	if brains.can_build(builder, def_name) == false then
		return nil
	end
	local safe = brain.profile.safe_danger
	local builder_def = builder.def
	local candidates: { { position: Vector3, score: number } } = {}
	local taken = siting.taken_spots(census)
	for _, spot in spots.all "metal" do
		local position = spot.position
		local from_home = geometry.distance_2d(position, brain.home)
		if max_distance ~= nil and from_home > max_distance then
			continue
		end
		if builder_def.footing.max_depth <= 0 and heightmap.water_depth(position.X, position.Z) > 0 then
			continue
		end
		if censuses.nearest_distance(taken, position) < siting.SAME_SPOT or siting.given_up(brain, position) then
			continue
		end
		if danger_field.peak_near(brain.field, position, SITING.GUARDED_RADIUS) >= safe then
			continue
		end
		-- another team's builder on its way to this spot that is nearer it would get there first
		local to_spot = geometry.distance_2d(builder.position, position)
		local beaten = false
		for _, claim in census.foreign_claims do
			if
				geometry.distance_2d(claim.position, position) < siting.SAME_SPOT
				and geometry.distance_2d(claim.from, position) < to_spot
			then
				beaten = true
				break
			end
		end
		if beaten then
			continue
		end
		local score = geometry.distance_2d(builder.position, position)
			+ from_home * brain.profile.extractor_home_weight
			- spot.multiplier * brain.profile.extractor_richness_weight
		table.insert(candidates, { position = position, score = score })
	end
	table.sort(candidates, function(a, b): boolean
		return a.score < b.score
	end)
	local tried = 0
	for _, candidate in candidates do
		if routes.route_danger(brain, builder.position, candidate.position) >= safe then
			continue
		end
		tried += 1
		if tried > EXTRACTOR_TRIES then
			break
		end
		local center = placement.ground_center(def_name, candidate.position.X, candidate.position.Z)
		if placement.can_place(def_name, center, 0, nil, brain.team) then
			return { def_name = def_name, position = center, facing = 0 }
		end
	end
	return nil
end

-- A plain extractor of its own, somewhere quiet, to build an advanced one over.
local function upgrade_task(brain: Brain, census: Census, builder: Entity): Task?
	local def_name = catalog.ADVANCED_EXTRACTOR
	if brains.can_build(builder, def_name) == false then
		return nil
	end
	local best: Entity? = nil
	local best_distance = math.huge
	-- advanced extractors, finished or not, and where its builders are on their way to put one up
	local upgrades = censuses.sites_of(
		census,
		censuses.buildings_of(census, def_name),
		function(planned: string): boolean
			return planned == def_name
		end
	)
	for _, extractor in census.extractors do
		if extractor.def_name ~= catalog.PLAIN_EXTRACTOR then
			continue
		end
		if
			danger_field.peak_near(brain.field, extractor.position, SITING.GUARDED_RADIUS) >= brain.profile.safe_danger
		then
			continue
		end
		if censuses.nearest_distance(upgrades, extractor.position) < siting.SAME_SPOT then
			continue
		end
		local distance = geometry.distance_2d(builder.position, extractor.position)
		if distance < best_distance then
			best = extractor
			best_distance = distance
		end
	end
	if best == nil then
		return nil
	end
	local center = placement.ground_center(def_name, best.position.X, best.position.Z)
	if placement.can_place(def_name, center, 0, nil, brain.team) == false then
		return nil
	end
	return { def_name = def_name, position = center, facing = 0 }
end

-- An extractor of its own with nothing to guard it and nothing on its way, and a guard beside it, on the side toward
-- the enemy if there is room there; none once the profile's extractor_guards of its extractors are guarded.
local function guard_task(brain: Brain, census: Census, builder: Entity): Task?
	local def_name = GUARD
	local share = brain.profile.extractor_guards
	if share <= 0 or brains.can_build(builder, def_name) == false then
		return nil
	end
	local best: Entity? = nil
	local best_distance = math.huge
	local guarded_count = 0
	local guards = censuses.sites_of(census, census.ground_defenses, hits_ground)
	for _, extractor in census.extractors do
		if censuses.nearest_distance(guards, extractor.position) <= SITING.GUARDED_RADIUS then
			guarded_count += 1
			continue
		end
		if
			danger_field.peak_near(brain.field, extractor.position, SITING.GUARDED_RADIUS) >= brain.profile.safe_danger
		then
			continue
		end
		local distance = geometry.distance_2d(builder.position, extractor.position)
		if distance < best_distance then
			best = extractor
			best_distance = distance
		end
	end
	if best == nil or (share < 1 and guarded_count >= math.floor(#census.extractors * share)) then
		return nil
	end
	local toward = geometry.flatten(-best.position)
	local ahead = if toward.Magnitude > 1 then best.position + toward.Unit * SITING.GUARD_RING_INNER else best.position
	return siting.ring_site(brain, census, def_name, ahead, 0, SITING.GUARD_RING_OUTER, 0)
end

-- A guard round home, in front of its labs, while it has fewer there than the profile's home_guards.
local function home_guard_task(brain: Brain, census: Census, builder: Entity): Task?
	local def_name = GUARD
	local wanted = brain.profile.home_guards
	if wanted <= 0 or brains.can_build(builder, def_name) == false then
		return nil
	end
	local guards = censuses.sites_of(census, census.ground_defenses, hits_ground)
	if censuses.count_within(guards, brain.home, brain.profile.base_radius) >= wanted then
		return nil
	end
	return siting.ring_site(
		brain,
		census,
		def_name,
		brain.home + brain.forward * SITING.HOME_GUARD_OFFSET,
		0,
		SITING.HOME_GUARD_RING,
		0
	)
end

-- Anti-air, beside whatever of its own is furthest from the anti-air it has: the dearest `builder` can build that costs
-- no more than the profile's air_defense_afford_seconds of the metal income.
local function air_defense_task(brain: Brain, census: Census, builder: Entity, economy: Economy): Task?
	local def_name = best_affordable(builder, catalog.AIR_DEFENSES, function(def: EntityDef): number
		return def.metal_cost
	end, economy.metal_income * brain.profile.air_defense_afford_seconds)
	if def_name == nil then
		return nil
	end
	local covered = censuses.sites_of(census, census.air_defenses, function(planned: string): boolean
		return catalog.role_of(planned).anti_air
	end)
	local best: Entity? = nil
	local best_gap = -1
	for _, building in census.structures do
		if building.state ~= "active" then
			continue
		end
		local role = catalog.role_of(building.def_name)
		if role.factory == false and catalog.ENERGY_DEFS[building.def_name] ~= true and role.extractor == false then
			continue
		end
		local gap = censuses.nearest_distance(covered, building.position)
		if gap > best_gap then
			best = building
			best_gap = gap
		end
	end
	if best == nil then
		return nil
	end
	return siting.ring_site(brain, census, def_name, best.position, SITING.AIR_RING_INNER, SITING.AIR_RING_OUTER, 0)
end

-- What `builder` should build for energy now, of the tiers of what makes it (catalog.ENERGY_TIERS): what the commander
-- builds (wind turbines) until the team makes the profile's constructor_energy_income, what a constructor builds
-- (advanced solar collectors) from there, and what an advanced constructor builds (fusion reactors) once it makes its
-- advanced_energy_income and has one to build it; the cheapest of a tier `builder` can build. A builder that can build
-- nothing of the highest tier the team has reached builds no energy, but in a stall.
local function energy_choice(brain: Brain, census: Census, economy: Economy, builder: Entity): string?
	local profile = brain.profile
	local reached = {
		true,
		economy.energy_income >= profile.constructor_energy_income,
		economy.energy_income >= profile.advanced_energy_income and census.advanced_builders > 0,
	}
	for tier = #catalog.ENERGY_TIERS, 1, -1 do
		if reached[tier] ~= true then
			continue
		end
		for _, def_name in catalog.ENERGY_TIERS[tier] do
			if brains.can_build(builder, def_name) then
				return def_name
			end
		end
		if tier > 1 and economy.energy_stalling == false then
			return nil
		end
	end
	return nil
end

local function energy_in_progress(census: Census): number
	local total = 0
	for def_name in catalog.ENERGY_DEFS do
		total += censuses.in_progress(census, def_name)
	end
	return total
end

local function energy_task(brain: Brain, census: Census, economy: Economy, builder: Entity): Task?
	local def_name = energy_choice(brain, census, economy, builder)
	if def_name == nil then
		return nil
	end
	return siting.cluster_site(brain, census, def_name)
end

-- The energy a second its converters burn at their full rate, the ones not finished or not started among them.
local function conversion_draw(census: Census): number
	local total = 0
	for _, def_name in catalog.CONVERTER_DEFS do
		local conversion = unit_defs.get(def_name).energy_conversion
		if conversion ~= nil then
			total += censuses.count_of(census, def_name) * conversion.energy_per_second
		end
	end
	return total
end

-- The energy income it wants for each metal of income now: what its labs spend the two in, give or take, which is the
-- profile's energy_factor_start when it begins and grows to its energy_factor_end over its energy_factor_seconds (as
-- BARb's economy.json "factor" does), since early on it builds mostly what costs little energy.
local function energy_per_metal(brain: Brain): number
	local profile = brain.profile
	local start, finish = profile.energy_factor_start, profile.energy_factor_end
	if start == finish then
		return start
	end
	local along = math.clamp((brains.now() - brain.started) / math.max(1, profile.energy_factor_seconds), 0, 1)
	return start + (finish - start) * along
end

-- The energy income it wants: enough for its metal (`energy_per_metal`), and enough to keep its converters running.
local function energy_wanted(brain: Brain, census: Census, economy: Economy): number
	return economy.metal_income * energy_per_metal(brain) + conversion_draw(census)
end

-- While its energy piles up: another energy store if it cannot yet hold enough for converters to work from, and
-- otherwise a converter to turn what piles up into metal, so long as it has room for the metal. Converters burn only
-- the energy over server/economy_settings.luau's CONVERTER_THRESHOLD of its store, so it first builds energy stores
-- while its energy piles up (the store over the profile's piling_fill full), until it can hold its storage_seconds of
-- its energy income and at least its converter_storage, or has its energy_stores_max of them; from there it builds
-- converters, advanced ones as big as burn no more than its converter_burn_share of the energy income, no more than its
-- converters_at_once at a time.
local function conversion_task(brain: Brain, census: Census, economy: Economy, builder: Entity): Task?
	local profile = brain.profile
	if economy.energy_fill < profile.piling_fill and economy.energy_overflowing == false then
		return nil
	end
	local store_wanted = math.max(profile.converter_storage, economy.energy_income * profile.storage_seconds)
	if
		economy.energy_capacity < store_wanted
		and count_all(census, catalog.ENERGY_STORES) < profile.energy_stores_max
	then
		local store = catalog.ENERGY_STORES[1]
		if brains.can_build(builder, store) and in_progress_all(census, catalog.ENERGY_STORES) == 0 then
			return siting.cluster_site(brain, census, store)
		end
		return nil
	end
	if economy.metal_overflowing then
		return nil
	end
	local def_name = best_affordable(builder, catalog.CONVERTER_DEFS, function(def: EntityDef): number
		return (def.energy_conversion :: types.EnergyConversion).energy_per_second
	end, economy.energy_income * profile.converter_burn_share)
	if def_name ~= nil and in_progress_all(census, catalog.CONVERTER_DEFS) < profile.converters_at_once then
		return siting.cluster_site(brain, census, def_name)
	end
	return nil
end

-- A construction turret beside its labs, now and then as its income grows: none until it makes the profile's
-- turret_income metal, then one for every metal_per_turret of it up to turrets_max, one at a time, the dearest that
-- costs no more than its turret_afford_seconds of the income.
local function turret_task(brain: Brain, census: Census, economy: Economy, builder: Entity): Task?
	local profile = brain.profile
	local income = economy.metal_income + economy.converted_metal
	if #census.factories == 0 or income < profile.turret_income or economy.metal_short or economy.energy_stalling then
		return nil
	end
	local turrets = count_all(census, catalog.TURRET_DEFS)
	local wanted = math.min(profile.turrets_max, math.floor(income / profile.metal_per_turret))
	if economy.metal_overflowing then
		wanted += 1
	end
	if turrets >= wanted or in_progress_all(census, catalog.TURRET_DEFS) > 0 then
		return nil
	end
	local def_name = best_affordable(builder, catalog.TURRET_DEFS, function(def: EntityDef): number
		return def.metal_cost
	end, income * profile.turret_afford_seconds)
	if def_name == nil then
		return nil
	end
	return siting.cluster_site(brain, census, def_name)
end

-- A lab of `def_name`, near home with its doorway toward the middle of the map, while it has fewer than `most`.
local function lab_task(brain: Brain, census: Census, builder: Entity, def_name: string, most: number): Task?
	if brains.can_build(builder, def_name) == false or censuses.count_of(census, def_name) >= most then
		return nil
	end
	local facing = geometry.snap_facing(math.atan2(brain.forward.X, brain.forward.Z))
	return siting.ring_site(
		brain,
		census,
		def_name,
		brain.home + brain.forward * SITING.LAB_OFFSET,
		0,
		SITING.LAB_SEARCH_RADIUS,
		facing
	)
end

-- The only line whose lab it may build if it may build only one; otherwise bots, unless a vehicle could not get from
-- home toward the middle of the map, which is when the ground is too rough for them; otherwise either, by a toss.
local function choose_line(brain: Brain): Line
	local bot_line: Line, vehicle_line: Line = "bot", "vehicle"
	local bots = brains.may_build(brain.team, catalog.LABS[bot_line].first)
	local vehicles = brains.may_build(brain.team, catalog.LABS[vehicle_line].first)
	if bots ~= vehicles then
		return if bots then bot_line else vehicle_line
	end
	local probe = unit_defs.get(catalog.constructor_of(vehicle_line))
	local toward = brain.home + brain.forward * LINE_PROBE
	if heightmap.in_bounds(toward.X, toward.Z) == false then
		toward = brain.home + brain.forward * LINE_PROBE_NEAR
	end
	local from = surface.position(probe, brain.home.X, brain.home.Z)
	local to = surface.position(probe, toward.X, toward.Z)
	if pathfinder.has_straight_path(probe, from, to) == false then
		return bot_line
	end
	return if rng.stream(brain.stream):NextNumber() < 0.5 then bot_line else vehicle_line
end

-- The line it plays, from now on: the one it was told, or has played already; or else the line of a lab it has (the
-- first of catalog.LINES it has one of); or else the one it chooses (`choose_line`).
local function resolve_line(brain: Brain, census: Census): Line
	local line: Line? = brain.line
	if line ~= nil then
		return line
	end
	local chosen: Line? = nil
	for _, candidate: Line in catalog.LINES do
		if chosen == nil and censuses.count_of(census, catalog.LABS[candidate].first) > 0 then
			chosen = candidate
		end
	end
	local resolved: Line = chosen or choose_line(brain)
	brain.line = resolved
	return resolved
end

-- Everything a builder may be given, in the order it is looked at (see the top of this file).
local WANTS: { Want } = {
	{
		name = "lab",
		gate = function(context: Context): boolean
			return context.brain.line ~= nil
		end,
		task = function(context: Context): Task?
			local brain, census = context.brain, context.census
			local lab = catalog.LABS[brain.line :: Line].first
			-- a lab past the first waits for the income to keep it busy
			local labs = censuses.count_of(census, lab)
			local most = if labs > 0
					and context.economy.metal_income < labs * brain.profile.metal_per_extra_lab
				then labs
				else brain.profile.labs
			return lab_task(brain, census, context.builder, lab, most)
		end,
	},
	{
		name = "energy_in_a_stall",
		gate = function(context: Context): boolean
			return context.economy.energy_stalling and energy_in_progress(context.census) < context.builders
		end,
		task = function(context: Context): Task?
			return energy_task(context.brain, context.census, context.economy, context.builder)
		end,
	},
	{
		name = "advanced_lab",
		gate = function(context: Context): boolean
			return context.brain.line ~= nil
				and context.economy.metal_income >= context.brain.profile.advanced_lab_income
				and #context.census.factories > 0
		end,
		task = function(context: Context): Task?
			local brain = context.brain
			return lab_task(brain, context.census, context.builder, catalog.LABS[brain.line :: Line].advanced, 1)
		end,
	},
	{
		name = "construction_turret",
		gate = function(_context: Context): boolean
			return true
		end,
		task = function(context: Context): Task?
			return turret_task(context.brain, context.census, context.economy, context.builder)
		end,
	},
	{
		name = "extractor",
		gate = function(context: Context): boolean
			local at_once = math.max(1, math.ceil(context.builders * context.brain.profile.extractor_builders))
			return censuses.in_progress(context.census, catalog.PLAIN_EXTRACTOR) < at_once
		end,
		task = function(context: Context): Task?
			return extractor_task(context.brain, context.census, context.builder, context.reach)
		end,
	},
	{
		name = "energy",
		gate = function(context: Context): boolean
			local brain, census, economy = context.brain, context.census, context.economy
			local at_once = math.max(1, math.ceil(context.builders / brain.profile.builders_per_energy_build))
			return economy.energy_income < energy_wanted(brain, census, economy)
				and energy_in_progress(census) < at_once
		end,
		task = function(context: Context): Task?
			return energy_task(context.brain, context.census, context.economy, context.builder)
		end,
	},
	{
		name = "conversion",
		gate = function(_context: Context): boolean
			return true
		end,
		task = function(context: Context): Task?
			return conversion_task(context.brain, context.census, context.economy, context.builder)
		end,
	},
	{
		name = "extractor_guard",
		gate = function(context: Context): boolean
			local brain = context.brain
			local profile = brain.profile
			-- guards by its extractors once it has played the profile's guard_after_seconds or makes its guard_income
			local due = brains.now() - brain.started >= profile.guard_after_seconds
				or context.economy.metal_income >= profile.guard_income
			return due
				and #context.census.factories > 0
				and censuses.in_progress(context.census, GUARD) < profile.guards_at_once
		end,
		task = function(context: Context): Task?
			return guard_task(context.brain, context.census, context.builder)
		end,
	},
	{
		name = "home_guard",
		gate = function(context: Context): boolean
			return #context.census.factories > 0
				and censuses.in_progress(context.census, GUARD) < context.brain.profile.guards_at_once
		end,
		task = function(context: Context): Task?
			return home_guard_task(context.brain, context.census, context.builder)
		end,
	},
	{
		name = "extractor_upgrade",
		gate = function(context: Context): boolean
			local census = context.census
			return censuses.in_progress(census, catalog.ADVANCED_EXTRACTOR) < census.advanced_builders
		end,
		task = function(context: Context): Task?
			return upgrade_task(context.brain, context.census, context.builder)
		end,
	},
	{
		name = "air_defense",
		gate = function(context: Context): boolean
			local brain, census = context.brain, context.census
			local profile = brain.profile
			local aircraft = brain.field.enemy_air_count
			local wanted = math.min(profile.air_defenses_max, math.ceil(aircraft / profile.aircraft_per_air_defense))
			if profile.air_defense < 1 then
				wanted = math.floor(wanted * profile.air_defense)
			end
			local have = #census.air_defenses + in_progress_all(census, catalog.AIR_DEFENSES)
			return aircraft >= profile.air_threat_count and have < wanted
		end,
		task = function(context: Context): Task?
			return air_defense_task(context.brain, context.census, context.builder, context.economy)
		end,
	},
	{
		name = "far_extractor",
		gate = function(_context: Context): boolean
			return true
		end,
		task = function(context: Context): Task?
			return extractor_task(context.brain, context.census, context.builder, context.reach)
		end,
	},
}

-- Something for `builder` to build, the first that is wanted of what it can build (WANTS), where it may go (its duty,
-- census.luau's `Duty`): what keeps to the base builds only there, and nothing is built at the end of a dangerous way.
local function choose_task(brain: Brain, census: Census, economy: Economy, builder: Entity): Task?
	local profile = brain.profile
	local duty = censuses.duty_of(census, builder)
	local context: Context = {
		brain = brain,
		census = census,
		economy = economy,
		builder = builder,
		builders = #census.builders,
		reach = duty.reach,
	}
	for _, want in WANTS do
		if want.gate(context) == false then
			continue
		end
		local task = want.task(context)
		if
			task ~= nil
			and (duty.ventures or geometry.distance_2d(task.position, brain.home) <= profile.base_radius)
			and routes.route_danger(brain, builder.position, task.position) < profile.safe_danger
		then
			return task
		end
	end
	return nil
end

return table.freeze({
	extractor_task = extractor_task,
	lab_task = lab_task,
	resolve_line = resolve_line,
	choose_task = choose_task,
})
