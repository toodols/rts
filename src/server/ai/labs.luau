--!strict
-- What a brain's labs make, each keeping the profile's factory_queue things queued: enough constructors (the profile's
-- constructors_min, one more for every metal_per_constructor of income up to constructors_max, and advanced ones the
-- same way), a rezbot or two while there are wrecks lying about, anti-air while the enemy flies, raiders while it is
-- short of a raid's worth, and otherwise a mix of whatever fights that its income can pay for (`fighter_for`). A
-- profile with an army_share spends only that share of its metal income on fighters: it banks the share as it comes in,
-- up to what its dearest fighter costs, and starts a fighter only once the bank would pay for it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(ServerScriptService.Server.state)
local production = require(ServerScriptService.Server.production)
local rng = require(ServerScriptService.Server.rng)

local danger_field = require(script.Parent.danger_field)
local brains = require(script.Parent.brains)
local catalog = require(script.Parent.catalog)
local censuses = require(script.Parent.census)
local groups = require(script.Parent.groups)
local assignments = require(script.Parent.assignments)

type Entity = types.Entity
type Brain = brains.Brain
type Census = censuses.Census
type Economy = censuses.Economy

-- The dearest of `options` its labs field now: what costs no more than the profile's afford_seconds of its income, or
-- the cheapest of them if nothing does.
local function afford_limit(brain: Brain, economy: Economy, options: { string }): number
	local cheapest = math.huge
	for _, name in options do
		cheapest = math.min(cheapest, unit_defs.get(name).metal_cost)
	end
	return math.max((economy.metal_income + economy.converted_metal) * brain.profile.afford_seconds, cheapest)
end

-- What a lab should make next of `options`: any it can afford (`afford_limit`) that is not worth less than the
-- profile's fodder_share of the dearest of those.
local function fighter_for(brain: Brain, economy: Economy, options: { string }): string?
	if #options == 0 then
		return nil
	end
	local limit = afford_limit(brain, economy, options)
	local dearest = 0
	for _, name in options do
		local cost = unit_defs.get(name).metal_cost
		if cost <= limit then
			dearest = math.max(dearest, cost)
		end
	end
	local chosen: { string } = {}
	for _, name in options do
		local cost = unit_defs.get(name).metal_cost
		if cost <= limit and cost >= dearest * brain.profile.fodder_share then
			table.insert(chosen, name)
		end
	end
	if #chosen == 0 then
		return nil
	end
	return chosen[rng.stream(brain.stream):NextInteger(1, #chosen)]
end

-- The fastest of `options` that goes on the ground and that it can afford (`afford_limit`), the cheapest of them on a
-- tie: what it raids with.
local function raider_for(brain: Brain, economy: Economy, options: { string }): string?
	if #options == 0 then
		return nil
	end
	local limit = afford_limit(brain, economy, options)
	local best: string? = nil
	local best_speed = -1
	local best_cost = math.huge
	for _, name in options do
		local def = unit_defs.get(name)
		if unit_defs.is_air(def) or def.metal_cost > limit then
			continue
		end
		local speed = def.max_speed or 0
		if speed > best_speed or (speed == best_speed and def.metal_cost < best_cost) then
			best = name
			best_speed = speed
			best_cost = def.metal_cost
		end
	end
	return best
end

local function product_for(brain: Brain, census: Census, economy: Economy, factory: Entity): string?
	local constructors: { string } = {}
	local rezbots: { string } = {}
	local anti_air: { string } = {}
	local fighters: { string } = {}
	local options = unit_defs.build_options(factory.def)
	for _, name in options do
		local def = unit_defs.get(name)
		if def.kind ~= "unit" or unit_defs.is_drone(def) or brains.may_build(brain.team, name) == false then
			continue
		end
		local role = catalog.role_of(name)
		if role.builder then
			table.insert(constructors, name)
		elseif role.rezbot then
			table.insert(rezbots, name)
		elseif role.hits_ground or role.hits_air then
			if role.anti_air then
				table.insert(anti_air, name)
			end
			if role.hits_ground then
				table.insert(fighters, name)
			end
		end
	end

	local income = economy.metal_income + economy.converted_metal
	local profile = brain.profile
	for _, name in constructors do
		local wanted = if catalog.role_of(name).advanced
			then math.clamp(
				1 + math.floor(income / profile.metal_per_advanced_constructor),
				1,
				profile.advanced_constructors_max
			)
			else math.clamp(
				profile.constructors_min + math.floor(income / profile.metal_per_constructor),
				profile.constructors_min,
				profile.constructors_max
			)
		if (census.counts[name] or 0) < wanted then
			return name
		end
	end
	-- short of metal, it makes nothing more than builders until it comes in
	if economy.metal_short then
		return nil
	end

	local safe_wrecks = 0
	for _, wreck in census.wrecks do
		if danger_field.at(brain.field, wreck.position) < profile.safe_danger then
			safe_wrecks += 1
		end
	end
	for _, name in rezbots do
		local wanted = if safe_wrecks > 0
			then math.min(profile.rezbots_max, 1 + math.floor(safe_wrecks / profile.wrecks_per_rezbot))
			else 0
		if (census.counts[name] or 0) < wanted then
			return name
		end
	end

	-- a profile that spends only a share of its income on fighters waits till that share has paid for the next, and
	-- banks no more than its dearest fighter
	local budget = math.huge
	if profile.army_share ~= nil then
		local banked = brain.army_budget
		banked.metal = math.min(banked.metal, afford_limit(brain, economy, fighters))
		budget = banked.metal
	end
	local function within_budget(name: string?): string?
		return if name ~= nil and unit_defs.get(name).metal_cost <= budget then name else nil
	end

	local aircraft = brain.field.enemy_air_count
	local early = profile.early_anti_air > 0
		and census.anti_air_units < profile.early_anti_air
		and catalog.any_aircraft_lab(census.enemy_structures)
	if
		#anti_air > 0
		and (
			early
			or (
				aircraft >= profile.air_threat_count
				and census.anti_air_units < math.ceil(aircraft * profile.anti_air_per_aircraft)
			)
		)
	then
		return within_budget(anti_air[rng.stream(brain.stream):NextInteger(1, #anti_air)])
	end
	-- short of raiders, the fastest it can make, until it has a raid's worth of them not out already
	local raid_size = groups.raid_wanted(brain)
	if raid_size ~= nil then
		local raider = raider_for(brain, economy, fighters)
		if raider ~= nil then
			local waiting = census.counts[raider] or 0
			for _, member_id in assignments.each(brain, "group") do
				local unit = state.get(member_id)
				if unit ~= nil and unit.def_name == raider then
					waiting -= 1
				end
			end
			if waiting < raid_size then
				return within_budget(raider)
			end
		end
	end
	return within_budget(fighter_for(brain, economy, fighters))
end

local function run_factories(brain: Brain, census: Census, economy: Economy)
	local share = brain.profile.army_share
	local banked = brain.army_budget
	local now = brains.now()
	if share ~= nil then
		banked.metal += (economy.metal_income + economy.converted_metal) * share * (now - banked.at)
	end
	banked.at = now
	for _, factory in census.factories do
		if #factory.queue >= brain.profile.factory_queue then
			continue
		end
		local product = product_for(brain, census, economy, factory)
		if product ~= nil and production.enqueue(factory, product) then
			censuses.bump(census.counts, product)
			local role = catalog.role_of(product)
			if share ~= nil and role.builder == false and role.rezbot == false then
				banked.metal -= unit_defs.get(product).metal_cost
			end
		end
	end
end

return table.freeze({
	run_factories = run_factories,
})
