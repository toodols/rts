-- Every team's metal and energy: what comes in (income, converters, refunds, reclaim), what it can hold, and every way
-- it is spent. Spending comes in two kinds.
--
-- A purchase (`spend`) is one thing bought whole at once, a shot or a disintegrator's blast: the team can afford it and
-- pays in full, or it cannot and pays nothing.
--
-- Work (`drain`) is spending that goes on all the time, a builder putting its buildpower into something
-- (server/work.luau): each tick every piece of work says how much it wants, and once the tick's work is all gathered it
-- is settled together (`settle`). A team that cannot pay for all of the metal, or all of the energy, has every piece
-- that needs it held back by the same share, rather than whichever happened to ask first getting all it wanted. Work
-- that costs nothing, like a repair, is never held back.
--
-- Whatever cannot be paid for is reported, as what held the spender back, here and nowhere else (server/flows.luau).
--
-- A team can be set to have no economy at all (`set_unlimited`): it can afford anything, however dear, and pays
-- nothing, as the scavengers do, whose Calamity alone would need more energy a shot than any store holds.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local spots = require(ReplicatedStorage.Shared.spots)
local environment = require(ReplicatedStorage.Shared.environment)
local switches = require(ReplicatedStorage.Shared.switches)

local economy_settings = require(script.Parent.economy_settings)
local state = require(script.Parent.state)
local wind = require(script.Parent.wind)
local flows = require(script.Parent.flows)
local match_stats = require(script.Parent.match_stats)

type Team = types.Team
type TeamId = types.TeamId
type EntityId = types.EntityId

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
-- Each team's resource bonus, as what its extractors and generators make is multiplied by: 2 for +100%, 0 for -100%.
-- It scales only what they make themselves, so not what converters, reclaim, a commander or a team's flat base income
-- bring in. A team with none set makes what its defs say.
local bonus_scales: { [TeamId]: number } = {}
-- The teams with no economy, which afford everything and pay nothing (`set_unlimited`).
local unlimited: { [TeamId]: boolean } = {}
-- How many seconds the rates take to follow what is happening, so a lump of reclaimed metal reads as a burst
-- that fades and not as a single spike.
local RATE_SMOOTHING_SECONDS = 1.5

-- A piece of work some entity does this tick for its team, at `rate` units of work a second, each unit costing
-- `metal_per_work` and `energy_per_work`, either of which may be nothing. `room` says how much work it can still take
-- this tick, nil once it has nothing left to do at all; `apply` does `work` of it, once it is paid for (`metal` and
-- `energy`), in a tick `delta` seconds long. `label` is what the infobox calls what it is spending on.
export type Drain = {
	entity_id: EntityId,
	team: TeamId,
	label: string,
	rate: number,
	metal_per_work: number,
	energy_per_work: number,
	room: () -> number?,
	apply: (work: number, metal: number, energy: number, delta: number) -> (),
}

-- This tick's work, in the order it was asked for.
local drains: { Drain } = {}

local function ledger_of(team_id: TeamId): Ledger
	local ledger = ledgers[team_id]
	if ledger == nil then
		ledger = { metal_in = 0, metal_out = 0, energy_in = 0, energy_out = 0 }
		ledgers[team_id] = ledger
	end
	return ledger
end

-- Folds the last step's gains and spending into each team's smoothed revenue and expenses.
local function smooth_rates(delta: number)
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

-- Gives `team_id` a resource bonus of `percent` (see game_modes.BONUS_MIN), from the next tick on.
local function set_bonus(team_id: TeamId, percent: number)
	bonus_scales[team_id] = 1 + percent / 100
end

-- `team_id`'s resource bonus in percent.
local function bonus_of(team_id: TeamId): number
	return ((bonus_scales[team_id] or 1) - 1) * 100
end

local function refresh_income()
	local metal_made: { [TeamId]: number } = {}
	local energy_made: { [TeamId]: number } = {}
	local metal_stored: { [TeamId]: number } = {}
	local energy_stored: { [TeamId]: number } = {}
	local converting: { [TeamId]: types.EnergyConversion } = {}
	table.clear(converters)
	for _, entity in state.all() do
		if entity.alive == false or entity.state ~= "active" then
			continue
		end
		local def = entity.def
		local bonus = bonus_scales[entity.team] or 1
		-- the bonus is for extractors and generators, and not for a unit that makes something as well, like a commander
		local metal_bonus = if def.spot == "metal" then bonus else 1
		local energy_bonus = if def.kind == "building" then bonus else 1
		if def.metal_income ~= nil then
			-- an extractor makes what its spot lets it
			local multiplier = if def.spot == "metal" then spots.multiplier_at(entity.position) else 1
			local made = def.metal_income * multiplier * metal_bonus
			metal_made[entity.team] = (metal_made[entity.team] or 0) + made
			flows.add(entity.id, if def.spot == "metal" then "Extracting" else "Generating", made, 0)
		end
		if def.energy_income ~= nil then
			local made = def.energy_income * energy_bonus
			energy_made[entity.team] = (energy_made[entity.team] or 0) + made
			flows.add(entity.id, "Generating", 0, made)
		end
		if def.wind_multiplier ~= nil then
			local made = wind.speed() * def.wind_multiplier * energy_bonus
			energy_made[entity.team] = (energy_made[entity.team] or 0) + made
			flows.add(entity.id, "Wind", 0, made)
		end
		if def.tidal_multiplier ~= nil then
			local made = environment.tidal_strength() * def.tidal_multiplier * energy_bonus
			energy_made[entity.team] = (energy_made[entity.team] or 0) + made
			flows.add(entity.id, "Tidal", 0, made)
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
		team.metal_income = economy_settings.METAL_INCOME + (metal_made[team_id] or 0)
		team.energy_income = economy_settings.ENERGY_INCOME + (energy_made[team_id] or 0)
		team.metal_capacity = economy_settings.METAL_CAPACITY + (metal_stored[team_id] or 0)
		team.energy_capacity = economy_settings.ENERGY_CAPACITY + (energy_stored[team_id] or 0)
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
		local spare = team.energy - team.energy_capacity * economy_settings.CONVERTER_THRESHOLD
		local room = team.metal_capacity - team.metal
		local by_energy = spare / wanted
		local by_room = room / (total.metal_per_second * delta)
		local fraction = math.clamp(math.min(1, by_energy, by_room), 0, 1)

		-- each converter runs at that fraction of its rate, and is held back if that is less than all of it
		local running: { types.Entity } = converters[team_id] or {}
		for _, converter in running do
			local conversion_def = converter.def.energy_conversion
			if conversion_def == nil then
				continue
			end
			flows.add(
				converter.id,
				"Converting",
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
		match_stats.made_metal(team_id, total.metal_per_second * delta * fraction)
	end
end

local function accrue(delta: number)
	smooth_rates(delta)
	refresh_income()
	for team_id, team in state.all_teams() do
		match_stats.made_metal(team_id, team.metal_income * delta)
		team.metal = math.min(team.metal_capacity, team.metal + team.metal_income * delta)
		team.energy = math.min(team.energy_capacity, team.energy + team.energy_income * delta)
		-- all of it counts as revenue, even what overflows a full store, so the HUD shows what the team makes
		local ledger = ledger_of(team_id)
		ledger.metal_in += team.metal_income * delta
		ledger.energy_in += team.energy_income * delta
	end
	convert(delta)
end

-- Metal recovered from reclaim, capped at storage. All of it counts as revenue, even what overflows a full store.
-- Returns how much was actually banked.
local function add_metal(team_id: TeamId, amount: number): number
	local team = state.get_team(team_id)
	if team == nil then
		return 0
	end
	local before = team.metal
	team.metal = math.min(team.metal_capacity, team.metal + amount)
	ledger_of(team_id).metal_in += amount
	return team.metal - before
end

local function add_energy(team_id: TeamId, amount: number): number
	local team = state.get_team(team_id)
	if team == nil then
		return 0
	end
	local before = team.energy
	team.energy = math.min(team.energy_capacity, team.energy + amount)
	ledger_of(team_id).energy_in += amount
	return team.energy - before
end

-- Whether team `team_id` has no economy: it affords everything and pays nothing.
local function set_unlimited(team_id: TeamId, on: boolean)
	unlimited[team_id] = on
end

-- `spender_id` of `team_id` buys something costing `metal` and `energy`, if the team can afford all of it, and says
-- whether it could. With nocost on, everything is affordable and nothing is spent.
local function spend(team_id: TeamId, metal: number, energy: number, spender_id: EntityId): boolean
	if switches.is_on "nocost" or unlimited[team_id] == true then
		return true
	end
	local team = state.get_team(team_id)
	if team == nil then
		return false
	end
	if team.metal < metal or team.energy < energy then
		flows.stall(spender_id, if team.metal < metal then "metal" else "energy")
		return false
	end
	team.metal -= metal
	team.energy -= energy
	record_spent(team_id, metal, energy)
	return true
end

-- Asks for `work` to be paid for when this tick's work is settled. Forgotten once it has been.
local function drain(work: Drain)
	table.insert(drains, work)
end

-- Pays for this tick's work, and has it done. Each team pays for as much of the metal and of the energy its work wants
-- as it can, the same share of every piece that needs it, and what it could not pay for all of is reported against
-- every such piece as what held it back.
local function settle(delta: number)
	if #drains == 0 then
		return
	end

	local metal_demand: { [TeamId]: number } = {}
	local energy_demand: { [TeamId]: number } = {}
	for _, work in drains do
		local wanted = work.rate * delta
		metal_demand[work.team] = (metal_demand[work.team] or 0) + wanted * work.metal_per_work
		energy_demand[work.team] = (energy_demand[work.team] or 0) + wanted * work.energy_per_work
	end

	-- each team's share of each resource: how much of this tick's demand for it it can actually pay for
	local metal_share: { [TeamId]: number } = {}
	local energy_share: { [TeamId]: number } = {}
	for team_id, metal_wanted in metal_demand do
		local team = state.get_team(team_id)
		local energy_wanted = energy_demand[team_id]
		local free = team ~= nil and unlimited[team_id] == true
		metal_share[team_id] = if team == nil
			then 0
			elseif free or metal_wanted <= 0 then 1
			else math.clamp(team.metal / metal_wanted, 0, 1)
		energy_share[team_id] = if team == nil
			then 0
			elseif free or energy_wanted <= 0 then 1
			else math.clamp(team.energy / energy_wanted, 0, 1)
	end

	local settling = table.clone(drains)
	table.clear(drains)
	for _, work in settling do
		local team = state.get_team(work.team)
		local room = work.room()
		if team == nil or room == nil then
			continue
		end
		-- held back by the scarcer of what it needs
		local factor = 1
		local short_of: flows.Stall? = nil
		if work.metal_per_work > 0 and metal_share[work.team] < factor then
			factor = metal_share[work.team]
			short_of = "metal"
		end
		if work.energy_per_work > 0 and energy_share[work.team] < factor then
			factor = energy_share[work.team]
			short_of = "energy"
		end
		if short_of ~= nil then
			flows.stall(work.entity_id, short_of)
		end
		local done = math.min(work.rate * delta * factor, room)
		if done <= 0 then
			continue
		end
		local metal = done * work.metal_per_work
		local energy = done * work.energy_per_work
		flows.add(work.entity_id, work.label, -metal / delta, -energy / delta)
		if unlimited[work.team] ~= true then
			team.metal = math.max(0, team.metal - metal)
			team.energy = math.max(0, team.energy - energy)
		end
		record_spent(work.team, metal, energy)
		work.apply(done, metal, energy, delta)
	end
end

-- Moves up to `amount` of `resource` from team `from` to team `to`, as much as the giver has and the taker has room
-- for, and returns how much moved.
local function transfer(from: TeamId, to: TeamId, resource: "metal" | "energy", amount: number): number
	local giver = state.get_team(from)
	local taker = state.get_team(to)
	if giver == nil or taker == nil then
		return 0
	end
	local held = if resource == "metal" then giver.metal else giver.energy
	-- what won't fit stays with the giver, so it mustn't reach the taker's revenue either
	local room = if resource == "metal"
		then taker.metal_capacity - taker.metal
		else taker.energy_capacity - taker.energy
	local offered = math.min(amount, held, room)
	if offered <= 0 then
		return 0
	end
	if resource == "metal" then
		local banked = add_metal(to, offered)
		giver.metal -= banked
		record_spent(from, banked, 0)
		return banked
	end
	local banked = add_energy(to, offered)
	giver.energy -= banked
	record_spent(from, 0, banked)
	return banked
end

return table.freeze({
	accrue = accrue,
	set_bonus = set_bonus,
	set_unlimited = set_unlimited,
	bonus_of = bonus_of,
	add_metal = add_metal,
	add_energy = add_energy,
	spend = spend,
	drain = drain,
	settle = settle,
	transfer = transfer,
})
