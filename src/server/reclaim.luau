-- Reclaiming: buildpower run backwards. The same buildpower that would have built a thing tears
-- it down, paying out metal at the same metal-per-buildpower rate construction charges.
--
-- A wreck has its own pools (50% of the dead unit's metal over 20% of its buildpower_cost), so
-- reclaiming a wreck is much faster than rebuilding the unit was. Reclaiming something still
-- standing unwinds its build progress and refunds metal at its own build rate, and that goes for something hanging
-- from a transport too, which is reached from under it. A reclaimable, a rock or a tree, is taken apart exactly as a
-- wreck is, out of the pools its def gives it, and pays out energy as well as metal.
--
-- It is work (server/work.luau) that costs nothing and pays out as it is done, when the tick's work is settled.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local flows = require(script.Parent.flows)
local match_stats = require(script.Parent.match_stats)
local deaths = require(script.Parent.deaths)
local work = require(script.Parent.work)

type Entity = types.Entity

-- Who is reclaiming, for whom, and what the infobox calls it ("Reclaiming Rock", "Reclaiming Grunt wreck").
type Reclaimer = {
	id: types.EntityId,
	team: types.TeamId,
	label: string,
}

local function can_reclaim(reclaimer: Entity, target: Entity): boolean
	if unit_defs.does(reclaimer.def, "reclaim") == false then
		return false
	end
	if reclaimer.state ~= "active" then
		return false
	end
	if target.id == reclaimer.id then
		return false
	end
	-- something that has to be destroyed cannot be taken apart while it stands, but what it leaves can be
	return target.def.reclaim_while_standing ~= false
end

-- Banks what `reclaimer` pulled out this step and counts it as its income, so the infobox shows it earning like a
-- generator. What a full store turned away is not income, and metal turned away marks it as held back (the infobox
-- only has room to say so on the metal tile).
local function pay(reclaimer: Reclaimer, metal: number, energy: number, delta: number)
	local metal_banked = if metal > 0 then economy.add_metal(reclaimer.team, metal) else 0
	local energy_banked = if energy > 0 then economy.add_energy(reclaimer.team, energy) else 0
	match_stats.made_metal(reclaimer.team, metal_banked)
	flows.add(reclaimer.id, reclaimer.label, metal_banked / delta, energy_banked / delta)
	if metal_banked < metal - 1e-6 then
		flows.stall(reclaimer.id, "storage")
	end
end

-- Remains, a wreck or a reclaimable, pay out their metal and energy in step with the buildpower put into them, at the
-- rates their metal and energy totals over their buildpower total set, and are gone once all of that has been put in.
local function reclaim_yield(target: Entity, yield: types.Yield, applied: number, reclaimer: Reclaimer, delta: number)
	if yield.buildpower_total <= 0 then
		pay(reclaimer, yield.metal_left, yield.energy_left, delta)
		deaths.destroy(target, "reclaimed")
		return
	end

	local consumed = math.min(applied, yield.buildpower_left)
	local metal = math.min(yield.metal_left, consumed * yield.metal_total / yield.buildpower_total)
	local energy = math.min(yield.energy_left, consumed * yield.energy_total / yield.buildpower_total)

	yield.buildpower_left -= consumed
	yield.metal_left -= metal
	yield.energy_left -= energy
	pay(reclaimer, metal, energy, delta)

	if yield.buildpower_left <= 0 then
		deaths.destroy(target, "reclaimed")
	end
end

-- Reclaiming something still standing takes its health away at the rate its buildpower cost sets:
-- each point of buildpower applied removes that fraction of its max health, so a reclaimer of
-- buildpower B strips a target of cost C in C / B seconds however hurt it was. When its health runs
-- out it is gone, leaving no wreck, and its metal goes to the reclaimer that finished it. A blueprint
-- counts for the buildpower actually put into it, and pays back the metal actually spent on it.
-- The metal comes in one lump at the end, but the reclaimer's income reads as the steady rate it is earning it at,
-- so the infobox does not sit at nothing and then flash a spike for a single tick.
local function reclaim_standing(target: Entity, applied: number, reclaimer: Reclaimer, delta: number)
	local def = target.def
	local is_blueprint = target.state == "blueprint"
	local cost = if is_blueprint then target.build_progress else def.buildpower_cost
	local metal = if is_blueprint then target.metal_paid else def.metal_cost

	if cost > 0 then
		flows.add(reclaimer.id, reclaimer.label, metal * math.min(1, applied / cost) / delta, 0)
		target.health -= target.max_health * applied / cost
		if target.health > 0 then
			return
		end
	end

	local banked = economy.add_metal(reclaimer.team, metal)
	match_stats.made_metal(reclaimer.team, banked)
	if banked < metal - 1e-6 then
		flows.stall(reclaimer.id, "storage")
	end
	deaths.destroy(target, "reclaimed")
end

-- `reclaimer` takes `target` apart with its buildpower this tick, if it can.
local function request(reclaimer: Entity, target: Entity)
	local buildpower = work.buildpower_of(reclaimer)
	if buildpower == nil or can_reclaim(reclaimer, target) == false then
		return
	end
	local label = `Reclaiming {target.def.display_name}`
	local paid: Reclaimer = { id = reclaimer.id, team = reclaimer.team, label = label }
	work.take(reclaimer, "reclaim", target, {
		entity_id = reclaimer.id,
		team = reclaimer.team,
		label = label,
		rate = buildpower,
		metal_per_work = 0,
		energy_per_work = 0,
		-- all it has, until it is gone: something another reclaimer finished off earlier pays nobody a second time
		room = function(): number?
			return if state.get(target.id, true) ~= nil then math.huge else nil
		end,
		apply = function(applied: number, _metal: number, _energy: number, delta: number)
			local yield = target.yield
			if yield ~= nil then
				reclaim_yield(target, yield, applied, paid, delta)
			else
				reclaim_standing(target, applied, paid, delta)
			end
		end,
	})
end

return table.freeze({
	request = request,
	can_reclaim = can_reclaim,
})
