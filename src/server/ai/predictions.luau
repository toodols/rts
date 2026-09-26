--!strict
-- The fight predictor (combat_sim.luau), as a brain asks it, as UAlbertaBot asks SparCraft: rather than weigh its
-- wave's worth against the danger round a target, it plays the fight out, what shoots what and from how far included.
-- With the profile's attack_rule "sim" its wave sets out only at a target it is told it beats, the cheapest such for
-- how far off it is (`choose_target`); with its retreat_rule "sim" a wave out pulls back once the fight it is in is
-- predicted to go against it (army.luau); with its defend_rule "sim" what is sent to see off an intruder is the least
-- that is predicted to beat it (defence.luau, `fewest_that_win`), as are its hunters and strikes (groups.luau); and with
-- its raid_rule "sim" a raid goes from one target it is predicted to beat to the next (`choose_raid_target`).
--
-- What of the enemy a fight at a place is predicted against (`enemies_near`): anything armed that stands still and
-- reaches within REACH_SLACK of it, anything armed that moves within UNIT_RADIUS (AIR_RADIUS for aircraft, which come
-- from further, faster), and what is unarmed within SOAK_RADIUS, which draws fire; a raid, which is quick and only
-- passes by, counts what moves on the ground within RAID_RADIUS rather than UNIT_RADIUS. A wave choosing where to go
-- predicts its fight at no more than CANDIDATES places, the nearest of its enemy's buildings no two within
-- CANDIDATE_SPACING of each other, and a raid the same of the enemy's extractors and constructors. A strike's target is
-- at least FRONT_SPACING from where it already fights, so that it opens a front of its own.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local brains = require(script.Parent.brains)
local catalog = require(script.Parent.catalog)
local censuses = require(script.Parent.census)
local combat_sim = require(script.Parent.combat_sim)
local sorties = require(script.Parent.sorties)

type Entity = types.Entity
type Brain = brains.Brain
type Census = censuses.Census

local REACH_SLACK = 20
local UNIT_RADIUS = 90
local AIR_RADIUS = 150
local SOAK_RADIUS = 30
local RAID_RADIUS = 45
local CANDIDATES = 6
local CANDIDATE_SPACING = 40
local FRONT_SPACING = 60

-- What of the enemy a fight at `at` would be fought against, for the fight predictor: whatever is armed and stands
-- still (a defence) that reaches within REACH_SLACK of it, whatever is armed and moves within UNIT_RADIUS of it
-- (AIR_RADIUS for an aircraft), which would come to the fight, and whatever is unarmed within SOAK_RADIUS, which draws
-- fire away from what fights. It sees what the danger field sees. What moves on the ground is looked for within
-- `unit_radius` if it is given (RAID_RADIUS, for a raid).
local function enemies_near(census: Census, at: Vector3, unit_radius: number?): { Entity }
	local found: { Entity } = {}
	for _, structure in census.enemy_structures do
		local reach = catalog.role_of(structure.def_name).reach
		local distance = geometry.distance_2d(structure.position, at)
		if distance <= SOAK_RADIUS or (reach > 0 and distance <= reach + REACH_SLACK) then
			table.insert(found, structure)
		end
	end
	for _, unit in census.enemy_units do
		local radius = if catalog.role_of(unit.def_name).reach <= 0
			then SOAK_RADIUS
			elseif unit_defs.is_air(unit.def) then AIR_RADIUS
			else unit_radius or UNIT_RADIUS
		if geometry.distance_2d(unit.position, at) <= radius then
			table.insert(found, unit)
		end
	end
	return found
end

-- The fight between `ours` and `theirs` as the fight predictor sees it, from where they stand or, with `approach`,
-- with ours coming up the way from `approach.from` to `approach.to`; whoever is watching is told how long it took.
local function predict(
	brain: Brain,
	ours: { Entity },
	theirs: { Entity },
	approach: { from: Vector3, to: Vector3 }?
): combat_sim.Outcome
	local started = os.clock()
	-- an entity is a fighter, with more besides
	local outcome = combat_sim.simulate(
		ours :: { any },
		theirs :: { any },
		if approach ~= nil then { approach = approach } else nil
	)
	sorties.predicted(brain, os.clock() - started)
	return outcome
end

-- Whether `position` is within FRONT_SPACING of one of `fronts`, where it already fights.
local function near_front(fronts: { Vector3 }, position: Vector3): boolean
	for _, other in fronts do
		if geometry.distance_2d(other, position) < FRONT_SPACING then
			return true
		end
	end
	return false
end

-- What to attack with `units`, standing at `from`, by the fight predictor (the profile's attack_rule "sim"): of the
-- enemy's buildings, or with none it would take on, of its units on the ground, the one whose fight `units` is
-- predicted to win by the profile's sim_attack_margin at the least cost, a target further off costing more by as much
-- as a costly fight does (its distance, times one and the share of the wave's worth the fight takes). Only CANDIDATES
-- are asked about, the nearest first, each at least CANDIDATE_SPACING from the others, since a fight at one building is
-- the fight at those beside it. As targets.luau's `nearest_weak` weighs the danger, and as UAlbertaBot picks what to
-- attack by SparCraft's say.
--
-- For a strike, targets near one of `avoid`, where it already fights, are left out, so that it opens a front of its
-- own; and with `buildings_only`, so are the enemy's units, which a small group would only chase.
local function choose_target(
	brain: Brain,
	census: Census,
	units: { Entity },
	from: Vector3,
	avoid: { Vector3 }?,
	buildings_only: boolean?
): Entity?
	local margin = brain.profile.sim_attack_margin
	local fronts = avoid or {}
	local pools: { { Entity } } = if buildings_only == true
		then { census.enemy_structures }
		else { census.enemy_structures, census.enemy_units }
	for _, pool in pools do
		local distances: { [Entity]: number } = {}
		local sorted: { Entity } = {}
		for _, target in pool do
			if unit_defs.is_air(target.def) == false and near_front(fronts, target.position) == false then
				table.insert(sorted, target)
				distances[target] = geometry.distance_2d(from, target.position)
			end
		end
		table.sort(sorted, function(a, b): boolean
			return distances[a] < distances[b]
		end)
		local candidates: { Entity } = {}
		for _, target in sorted do
			if #candidates >= CANDIDATES then
				break
			end
			local apart = true
			for _, other in candidates do
				if geometry.distance_2d(other.position, target.position) < CANDIDATE_SPACING then
					apart = false
					break
				end
			end
			if apart then
				table.insert(candidates, target)
			end
		end
		local best: Entity? = nil
		local best_cost = math.huge
		for _, target in candidates do
			local outcome =
				predict(brain, units, enemies_near(census, target.position), { from = from, to = target.position })
			if outcome.margin < margin then
				continue
			end
			local lost = if outcome.start_worth[1] > 0 then 1 - outcome.worth[1] / outcome.start_worth[1] else 0
			local cost = distances[target] * (1 + lost)
			if cost < best_cost then
				best = target
				best_cost = cost
			end
		end
		if best ~= nil then
			return best
		end
	end
	return nil
end

-- How many of `line`, from the first, at least `least`, are the fewest that the fight predictor says beat `theirs` by
-- `margin`, coming up the way `approach` says if it is given; nil when all of them would not. Found by halving.
local function fewest_that_win(
	brain: Brain,
	line: { Entity },
	theirs: { Entity },
	margin: number,
	least: number,
	approach: { from: Vector3, to: Vector3 }?
): number?
	local function wins(count: number): boolean
		return predict(brain, table.move(line, 1, count, 1, {}), theirs, approach).margin >= margin
	end
	if #line == 0 or wins(#line) == false then
		return nil
	end
	local low, high = math.min(math.max(1, least), #line), #line
	while low < high do
		local middle = (low + high) // 2
		if wins(middle) then
			high = middle
		else
			low = middle + 1
		end
	end
	return low
end

-- A raid's next target by the fight predictor (the profile's raid_rule "sim"): of the enemy's extractors and
-- constructors (not its commander), the nearest `from` first, a constructor's way counting for less by the profile's
-- raid_builder_preference, the first the raid, `members`, is predicted to beat by sim_attack_margin. No more than
-- CANDIDATES are asked about, no two within CANDIDATE_SPACING, and none near one of `avoid`, where another group
-- already is; and slipping away from a threat at `away_from`, only what lies on the far side of the raid from it. So a
-- raid goes on from one undefended target to the next, as BARb's RaidTask does.
local function choose_raid_target(
	brain: Brain,
	census: Census,
	members: { Entity },
	from: Vector3,
	avoid: { Vector3 },
	away_from: Vector3?
): Entity?
	local costs: { [Entity]: number } = {}
	local sorted: { Entity } = {}
	local function consider(target: Entity, cost: number)
		if
			away_from ~= nil
			and geometry.flatten(target.position - from):Dot(geometry.flatten(from - away_from)) <= 0
		then
			return
		end
		if near_front(avoid, target.position) then
			return
		end
		costs[target] = cost
		table.insert(sorted, target)
	end
	for _, structure in census.enemy_structures do
		if catalog.role_of(structure.def_name).extractor then
			consider(structure, geometry.distance_2d(from, structure.position))
		end
	end
	for _, unit in census.enemy_units do
		local role = catalog.role_of(unit.def_name)
		if role.builder and role.commander == false and unit_defs.is_air(unit.def) == false then
			consider(
				unit,
				geometry.distance_2d(from, unit.position) / math.max(0.1, brain.profile.raid_builder_preference)
			)
		end
	end
	table.sort(sorted, function(a, b): boolean
		return costs[a] < costs[b]
	end)
	local asked: { Entity } = {}
	for _, target in sorted do
		if #asked >= CANDIDATES then
			break
		end
		local apart = true
		for _, other in asked do
			if geometry.distance_2d(other.position, target.position) < CANDIDATE_SPACING then
				apart = false
				break
			end
		end
		if apart == false then
			continue
		end
		table.insert(asked, target)
		local outcome = predict(
			brain,
			members,
			enemies_near(census, target.position, RAID_RADIUS),
			{ from = from, to = target.position }
		)
		if outcome.margin >= brain.profile.sim_attack_margin then
			return target
		end
	end
	return nil
end

return table.freeze({
	RAID_RADIUS = RAID_RADIUS,
	enemies_near = enemies_near,
	predict = predict,
	choose_target = choose_target,
	fewest_that_win = fewest_that_win,
	choose_raid_target = choose_raid_target,
})
