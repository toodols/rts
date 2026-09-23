-- Income and storage. Construction and reclaim move resources; this module only adds the trickle
-- and enforces the storage ceiling.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local environment = require(ReplicatedStorage.Shared.environment)

local state = require(script.Parent.state)
local wind = require(script.Parent.wind)
local flows = require(script.Parent.flows)
local nocost = require(script.Parent.nocost)

type Team = types.Team
type TeamId = types.TeamId

-- A team income and storage are the flat base plus whatever its finished commander, generators,
-- extractors and stores add. Recomputed every tick, so one that dies or is reclaimed stops counting
-- at once and a finished blueprint starts counting at once, and the HUD reads the same numbers the
-- bank works from.
-- What each team's converters can do together, from the last refresh.
local conversion: { [TeamId]: types.EnergyConversion? } = {}
-- The converters behind it, whose rates are settled once it is known how hard they can run.
local converters: { [TeamId]: { types.Entity } } = {}

-- What each team has gained and spent since the last step settled it, before it is smoothed into rates.
type Ledger = { metal_in: number, metal_out: number, energy_in: number, energy_out: number }
local ledgers: { [TeamId]: Ledger } = {}
-- How many seconds the rates take to follow what is happening, so a lump of reclaimed metal reads as a burst
-- that fades and not as a single spike.
local RATE_SMOOTHING_SECONDS = 1.5

local function ledger_of(team_id: TeamId): Ledger
	local ledger = ledgers[team_id]
	if ledger == nil then
		ledger = { metal_in = 0, metal_out = 0, energy_in = 0, energy_out = 0 }
		ledgers[team_id] = ledger
	end
	return ledger
end

-- Folds the last step's gains and spending into each team's smoothed revenue and expenses.
local function settle(delta: number)
	local blend = math.min(1, delta / RATE_SMOOTHING_SECONDS)
	for team_id, team in state.all_teams() do
		local ledger = ledger_of(team_id)
		team.metal_revenue += (ledger.metal_in / delta - team.metal_revenue) * blend
		team.metal_expense += (ledger.metal_out / delta - team.metal_expense) * blend
		team.energy_revenue += (ledger.energy_in / delta - team.energy_revenue) * blend
		team.energy_expense += (ledger.energy_out / delta - team.energy_expense) * blend
		ledger.metal_in = 0
		ledger.metal_out = 0
		ledger.energy_in = 0
		ledger.energy_out = 0
	end
end

-- Spending that took the resource out directly, like building, tells the ledger about it here.
local function record_spent(team_id: TeamId, metal: number, energy: number)
	local ledger = ledger_of(team_id)
	ledger.metal_out += metal
	ledger.energy_out += energy
end

local function refresh_income()
	local metal_made: { [TeamId]: number } = {}
	local energy_made: { [TeamId]: number } = {}
	local metal_stored: { [TeamId]: number } = {}
	local energy_stored: { [TeamId]: number } = {}
	local converting: { [TeamId]: types.EnergyConversion } = {}
	table.clear(converters)
	for _, entity in state.all() do
		if
			entity.alive == false
			or entity.state ~= "active"
			or entity.kind == "wreck"
			or entity.kind == "reclaimable"
		then
			continue
		end
		local def = unit_defs.get(entity.def_name)
		if def.metal_income ~= nil then
			-- an extractor makes what its spot lets it
			local multiplier = if def.requires_metal_spot == true then metal_spots.multiplier_at(entity.position) else 1
			metal_made[entity.team] = (metal_made[entity.team] or 0) + def.metal_income * multiplier
			flows.add(entity.id, def.metal_income * multiplier, 0)
		end
		if def.energy_income ~= nil then
			energy_made[entity.team] = (energy_made[entity.team] or 0) + def.energy_income
			flows.add(entity.id, 0, def.energy_income)
		end
		if def.wind_multiplier ~= nil then
			energy_made[entity.team] = (energy_made[entity.team] or 0) + wind.speed() * def.wind_multiplier
			flows.add(entity.id, 0, wind.speed() * def.wind_multiplier)
		end
		if def.tidal_multiplier ~= nil then
			local made = environment.tidal_strength() * def.tidal_multiplier
			energy_made[entity.team] = (energy_made[entity.team] or 0) + made
			flows.add(entity.id, 0, made)
		end
		if def.energy_conversion ~= nil then
			local total = converting[entity.team]
			if total == nil then
				total = { energy_per_second = 0, metal_per_second = 0 }
				converting[entity.team] = total
			end
			total.energy_per_second += def.energy_conversion.energy_per_second
			if converters[entity.team] == nil then
				converters[entity.team] = {}
			end
			table.insert(converters[entity.team], entity)
			total.metal_per_second += def.energy_conversion.metal_per_second
		end
		if def.metal_storage ~= nil then
			metal_stored[entity.team] = (metal_stored[entity.team] or 0) + def.metal_storage
		end
		if def.energy_storage ~= nil then
			energy_stored[entity.team] = (energy_stored[entity.team] or 0) + def.energy_storage
		end
	end
	for team_id, team in state.all_teams() do
		team.metal_income = config.METAL_INCOME + (metal_made[team_id] or 0)
		team.energy_income = config.ENERGY_INCOME + (energy_made[team_id] or 0)
		team.metal_capacity = config.METAL_CAPACITY + (metal_stored[team_id] or 0)
		team.energy_capacity = config.ENERGY_CAPACITY + (energy_stored[team_id] or 0)
		conversion[team_id] = converting[team_id]
	end
end

-- Converters turn energy into metal, but only the energy above the threshold, and only as much as the
-- metal storage has room for. They run at the same fraction of their full rate whichever limit is met.
local function convert(delta: number)
	for team_id, team in state.all_teams() do
		local total = conversion[team_id]
		if total == nil then
			continue
		end
		local wanted = total.energy_per_second * delta
		local spare = team.energy - team.energy_capacity * config.CONVERTER_THRESHOLD
		local room = team.metal_capacity - team.metal
		local by_energy = spare / wanted
		local by_room = room / (total.metal_per_second * delta)
		local fraction = math.clamp(math.min(1, by_energy, by_room), 0, 1)

		-- each converter runs at that fraction of its rate, and is held back if that is less than all of it
		for _, converter in converters[team_id] or {} do
			local conversion_def = unit_defs.get(converter.def_name).energy_conversion
			if conversion_def == nil then
				continue
			end
			flows.add(
				converter.id,
				conversion_def.metal_per_second * fraction,
				-conversion_def.energy_per_second * fraction
			)
			if fraction < 1 then
				flows.stall(converter.id, if by_room < by_energy then "storage" else "energy")
			end
		end

		if fraction <= 0 then
			continue
		end
		team.energy -= wanted * fraction
		team.metal += total.metal_per_second * delta * fraction
		local ledger = ledger_of(team_id)
		ledger.energy_out += wanted * fraction
		ledger.metal_in += total.metal_per_second * delta * fraction
	end
end

local function accrue(delta: number)
	settle(delta)
	refresh_income()
	for team_id, team in state.all_teams() do
		local metal_before = team.metal
		local energy_before = team.energy
		team.metal = math.min(team.metal_capacity, team.metal + team.metal_income * delta)
		team.energy = math.min(team.energy_capacity, team.energy + team.energy_income * delta)
		-- only what was actually banked counts, so income wasted on a full store is not revenue
		local ledger = ledger_of(team_id)
		ledger.metal_in += team.metal - metal_before
		ledger.energy_in += team.energy - energy_before
	end
	convert(delta)
end

-- Metal recovered from reclaim, capped at storage. Returns how much was actually banked.
local function add_metal(team_id: TeamId, amount: number): number
	local team = state.get_team(team_id)
	if team == nil then
		return 0
	end
	local before = team.metal
	team.metal = math.min(team.metal_capacity, team.metal + amount)
	ledger_of(team_id).metal_in += team.metal - before
	return team.metal - before
end

local function add_energy(team_id: TeamId, amount: number): number
	local team = state.get_team(team_id)
	if team == nil then
		return 0
	end
	local before = team.energy
	team.energy = math.min(team.energy_capacity, team.energy + amount)
	ledger_of(team_id).energy_in += team.energy - before
	return team.energy - before
end

-- Spends if the team can afford it in full, otherwise spends nothing. With nocost on, everything is affordable and
-- nothing is spent.
local function try_spend(team_id: TeamId, metal: number, energy: number): boolean
	if nocost.is_enabled() then
		return true
	end
	local team = state.get_team(team_id)
	if team == nil then
		return false
	end
	if team.metal < metal or team.energy < energy then
		return false
	end
	team.metal -= metal
	team.energy -= energy
	record_spent(team_id, metal, energy)
	return true
end

return table.freeze({
	accrue = accrue,
	add_metal = add_metal,
	add_energy = add_energy,
	try_spend = try_spend,
	record_spent = record_spent,
})
