--!strict
-- What a brain's army and raids go after. The army attacks only what its profile's attack_rule says it beats
-- (`CHOOSERS`): by "danger", something the danger round which, times the profile's attack_superiority, is under its
-- worth; by "sim", what the fight predictor says it beats (predictions.luau). Raids weigh the danger the same way with
-- the profile's raid_superiority (`choose_raid_target`); and an enemy that has come within the profile's defend_radius
-- of home, or its extractor_alert_radius of an extractor, is seen off first (`nearest_intruder`), unless a hunt is
-- after it. What hunts go after is the enemy's armed units in its territory (`intruders`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

local danger_field = require(script.Parent.danger_field)
local brains = require(script.Parent.brains)
local catalog = require(script.Parent.catalog)
local censuses = require(script.Parent.census)
local predictions = require(script.Parent.predictions)

type Entity = types.Entity
type Brain = brains.Brain
type Census = censuses.Census
type Rule = ai_profiles.Rule

-- The nearest enemy that can fight and has come close to home, or to one of its extractors, and that no hunt is after.
local function nearest_intruder(brain: Brain, census: Census): Entity?
	local best: Entity? = nil
	local best_distance = math.huge
	for _, enemy in census.enemy_units do
		local role = catalog.role_of(enemy.def_name)
		if role.hits_ground == false or brain.groups.hunted[enemy.id] == true then
			continue
		end
		local distance = geometry.distance_2d(enemy.position, brain.home)
		local near = distance <= brain.profile.defend_radius
		if near == false then
			for _, extractor in census.extractors do
				if geometry.distance_2d(enemy.position, extractor.position) <= brain.profile.extractor_alert_radius then
					near = true
					break
				end
			end
		end
		if near and distance < best_distance then
			best = enemy
			best_distance = distance
		end
	end
	return best
end

-- The enemy's armed units on the ground, but its commander, that have come into its territory: within the profile's
-- hunt_radius of one of its extractors, or of the base (its base_radius and that).
local function intruders(brain: Brain, census: Census): { Entity }
	local radius = brain.profile.hunt_radius
	local found: { Entity } = {}
	for _, enemy in census.enemy_units do
		local role = catalog.role_of(enemy.def_name)
		if
			role.hits_ground == false
			or (role.commander and brain.profile.hunts_commanders == false)
			or unit_defs.is_air(enemy.def)
		then
			continue
		end
		local inside = geometry.distance_2d(enemy.position, brain.home) <= brain.profile.base_radius + radius
		if inside == false then
			for _, extractor in census.extractors do
				if geometry.distance_2d(enemy.position, extractor.position) <= radius then
					inside = true
					break
				end
			end
		end
		if inside then
			table.insert(found, enemy)
		end
	end
	return found
end

-- Of `targets`, the one nearest `from` that stands where the danger times `superiority` is under `worth`, the danger
-- counting against it as distance does; or nil.
local function nearest_weak(
	brain: Brain,
	targets: { Entity },
	from: Vector3,
	worth: number,
	superiority: number,
	wanted: (Entity) -> boolean
): Entity?
	local best: Entity? = nil
	local best_score = math.huge
	for _, target in targets do
		if wanted(target) == false then
			continue
		end
		local danger = danger_field.peak_near(brain.field, target.position, brain.profile.target_danger_radius)
		if danger * superiority > worth then
			continue
		end
		local score = geometry.distance_2d(from, target.position) * (1 + danger / math.max(worth, 1))
		if score < best_score then
			best = target
			best_score = score
		end
	end
	return best
end

local function any_target(_target: Entity): boolean
	return true
end

local function on_the_ground(target: Entity): boolean
	return unit_defs.is_air(target.def) == false
end

-- What to attack with `units`, worth `worth`, standing at `from`, by each attack_rule: by "danger", the enemy's
-- building nearest `from` that stands where the danger is well under `worth` (the profile's attack_superiority), or
-- with none, a unit of theirs on the ground that does; by "sim", what the fight predictor says (predictions.luau's
-- `choose_target`).
local CHOOSERS: { [Rule]: (Brain, Census, { Entity }, Vector3, number) -> Entity? } = table.freeze({
	danger = function(brain: Brain, census: Census, _units: { Entity }, from: Vector3, worth: number): Entity?
		local superiority = brain.profile.attack_superiority
		return nearest_weak(brain, census.enemy_structures, from, worth, superiority, any_target)
			or nearest_weak(brain, census.enemy_units, from, worth, superiority, on_the_ground)
	end,
	sim = function(brain: Brain, census: Census, units: { Entity }, from: Vector3, _worth: number): Entity?
		return predictions.choose_target(brain, census, units, from)
	end,
})

local function choose_target(brain: Brain, census: Census, units: { Entity }, from: Vector3, worth: number): Entity?
	return CHOOSERS[brain.profile.attack_rule](brain, census, units, from, worth)
end

-- What a raid goes after: the enemy's extractor or constructor (not its commander, which fights) nearest `from` that
-- stands where the danger is well under the raid's `worth` (the profile's raid_superiority).
local function choose_raid_target(brain: Brain, census: Census, from: Vector3, worth: number): Entity?
	local superiority = brain.profile.raid_superiority
	local extractor = nearest_weak(
		brain,
		census.enemy_structures,
		from,
		worth,
		superiority,
		function(target: Entity): boolean
			return catalog.role_of(target.def_name).extractor
		end
	)
	local builder = nearest_weak(brain, census.enemy_units, from, worth, superiority, function(target: Entity): boolean
		local role = catalog.role_of(target.def_name)
		return role.builder and role.commander == false
	end)
	if extractor == nil or builder == nil then
		return extractor or builder
	end
	-- of the two, the nearer, the constructor's way counting for less by the profile's raid_builder_preference
	local to_builder = geometry.distance_2d(from, builder.position)
	local to_extractor = geometry.distance_2d(from, extractor.position)
	return if to_builder < to_extractor * brain.profile.raid_builder_preference then builder else extractor
end

return table.freeze({
	nearest_intruder = nearest_intruder,
	intruders = intruders,
	choose_target = choose_target,
	choose_raid_target = choose_raid_target,
})
