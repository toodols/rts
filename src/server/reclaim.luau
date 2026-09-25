-- Reclaiming: buildpower run backwards. The same buildpower that would have built a thing tears
-- it down, paying out metal at the same metal-per-buildpower rate construction charges.
--
-- A wreck has its own pools (50% of the dead unit's metal over 20% of its buildpower_cost), so
-- reclaiming a wreck is much faster than rebuilding the unit was. Reclaiming something still
-- standing unwinds its build progress and refunds metal at its own build rate, and that goes for something hanging
-- from a transport too, which is reached from under it. A reclaimable, a rock or a tree, is taken apart exactly as a
-- wreck is, out of the pools its def gives it, and pays out energy as well as metal.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local flows = require(script.Parent.flows)
local match_stats = require(script.Parent.match_stats)
local alliances = require(script.Parent.alliances)
local combat = require(script.Parent.combat)

type Entity = types.Entity

type Request = {
	reclaimer_id: types.EntityId,
	team: types.TeamId,
	target_id: types.EntityId,
	buildpower: number,
}

local pending: { Request } = {}
-- See construction.luau: this tick's and last tick's workers, so guards do not depend on order.
local working: { [types.EntityId]: types.EntityId } = {}
local previous_working: { [types.EntityId]: types.EntityId } = {}

local function begin_tick()
	table.clear(pending)
	previous_working, working = working, previous_working
	table.clear(working)
end

local function can_reclaim(reclaimer: Entity, target: Entity): boolean
	local def = unit_defs.of(reclaimer)
	if def.reclaiming == false or def.buildpower == nil then
		return false
	end
	if reclaimer.state ~= "active" then
		return false
	end
	if target.id == reclaimer.id then
		return false
	end
	-- something that has to be destroyed cannot be taken apart while it stands, but what it leaves can be
	if
		target.kind ~= "wreck"
		and target.kind ~= "reclaimable"
		and unit_defs.of(target).reclaimable == false
	then
		return false
	end
	return true
end

local function request(reclaimer: Entity, target: Entity)
	local def = unit_defs.of(reclaimer)
	local buildpower = def.buildpower
	if buildpower == nil then
		return
	end
	if can_reclaim(reclaimer, target) == false then
		return
	end
	working[reclaimer.id] = target.id
	table.insert(pending, {
		reclaimer_id = reclaimer.id,
		team = reclaimer.team,
		target_id = target.id,
		buildpower = buildpower,
	})
end

-- What `reclaimer` pulled apart this tick, if it is still standing. Read after the step, like
-- construction.target_of.
local function target_of(reclaimer_id: types.EntityId): types.EntityId?
	for _, entry in pending do
		if entry.reclaimer_id ~= reclaimer_id then
			continue
		end
		local target = state.find(entry.target_id)
		if target ~= nil and target.alive then
			return target.id
		end
	end
	return nil
end

-- Whether `target` is being reclaimed, this tick or last, by something of its own side or an ally's.
local function is_reclaimed_by_ally(target: Entity): boolean
	for _, record in { working, previous_working } do
		for reclaimer_id, target_id in record do
			if target_id ~= target.id then
				continue
			end
			local reclaimer = state.get(reclaimer_id)
			if reclaimer ~= nil and reclaimer.alive and alliances.are_allied(reclaimer.team, target.team) then
				return true
			end
		end
	end
	return false
end

-- The entity `reclaimer_id` reclaimed this tick or last, if it is still there.
local function recent_target_of(reclaimer_id: types.EntityId): types.EntityId?
	local target_id = working[reclaimer_id]
	if target_id == nil then
		target_id = previous_working[reclaimer_id]
	end
	if target_id == nil then
		return nil
	end
	local target = state.find(target_id)
	if target ~= nil and target.alive then
		return target.id
	end
	return nil
end

-- What reclaiming `target_id` is called in the infobox's list of where a reclaimer's income comes from: "Reclaiming
-- Rock", "Reclaiming Grunt wreck". The target may already be gone by the time its last payout lands.
local function reclaim_label(target_id: types.EntityId): string
	local target = state.find(target_id)
	if target == nil then
		return "Reclaiming"
	end
	local name = unit_defs.of(target).display_name
	return if target.kind == "wreck" then `Reclaiming {name} wreck` else `Reclaiming {name}`
end

-- Banks what `entry`'s reclaimer pulled out this step and counts it as that reclaimer's income, so the infobox
-- shows it earning like a generator. What a full store turned away is not income, and metal turned away marks it
-- as held back (the infobox only has room to say so on the metal tile).
local function pay(entry: Request, metal: number, energy: number, delta: number)
	local metal_banked = if metal > 0 then economy.add_metal(entry.team, metal) else 0
	local energy_banked = if energy > 0 then economy.add_energy(entry.team, energy) else 0
	match_stats.made_metal(entry.team, metal_banked)
	flows.add(entry.reclaimer_id, reclaim_label(entry.target_id), metal_banked / delta, energy_banked / delta)
	if metal_banked < metal - 1e-6 then
		flows.stall(entry.reclaimer_id, "storage")
	end
end

local function reclaim_wreck(target: Entity, applied: number, entry: Request, delta: number)
	local wreck = target.wreck
	if wreck == nil then
		return
	end
	if wreck.buildpower_total <= 0 then
		state.mark_dead(target)
		return
	end

	local consumed = math.min(applied, wreck.buildpower_left)
	local metal = consumed * (wreck.metal_total / wreck.buildpower_total)

	wreck.buildpower_left -= consumed
	wreck.metal_left = math.max(0, wreck.metal_left - metal)
	pay(entry, metal, 0, delta)

	if wreck.buildpower_left <= 0 then
		state.mark_dead(target)
	end
end

-- A reclaimable pays out its metal and energy in step with the buildpower put into it, at the rates its metal and
-- energy totals over its buildpower total set, and is gone once all of that has been put in.
local function reclaim_yield(target: Entity, applied: number, entry: Request, delta: number)
	local yield = target.yield
	if yield == nil then
		return
	end
	if yield.buildpower_total <= 0 then
		pay(entry, yield.metal_left, yield.energy_left, delta)
		state.mark_dead(target)
		return
	end

	local consumed = math.min(applied, yield.buildpower_left)
	local metal = math.min(yield.metal_left, consumed * yield.metal_total / yield.buildpower_total)
	local energy = math.min(yield.energy_left, consumed * yield.energy_total / yield.buildpower_total)

	yield.buildpower_left -= consumed
	yield.metal_left -= metal
	yield.energy_left -= energy
	pay(entry, metal, energy, delta)

	if yield.buildpower_left <= 0 then
		state.mark_dead(target)
	end
end

-- Reclaiming something still standing takes its health away at the rate its buildpower cost sets:
-- each point of buildpower applied removes that fraction of its max health, so a reclaimer of
-- buildpower B strips a target of cost C in C / B seconds however hurt it was. When its health runs
-- out it is gone, leaving no wreck, and its metal goes to the reclaimer that finished it. A blueprint
-- counts for the buildpower actually put into it, and pays back the metal actually spent on it.
-- The metal comes in one lump at the end, but the reclaimer's income reads as the steady rate it is earning it at,
-- so the infobox does not sit at nothing and then flash a spike for a single tick.
local function reclaim_standing(target: Entity, applied: number, entry: Request, delta: number)
	local def = unit_defs.of(target)
	local is_blueprint = target.state == "blueprint"
	local cost = if is_blueprint then target.build_progress else def.buildpower_cost
	local metal = if is_blueprint then target.metal_paid else def.metal_cost

	if cost > 0 then
		flows.add(entry.reclaimer_id, reclaim_label(target.id), metal * math.min(1, applied / cost) / delta, 0)
		target.health -= target.max_health * applied / cost
		if target.health > 0 then
			return
		end
	end

	local banked = economy.add_metal(entry.team, metal)
	match_stats.made_metal(entry.team, banked)
	if banked < metal - 1e-6 then
		flows.stall(entry.reclaimer_id, "storage")
	end
	state.mark_dead(target)
	-- a transport taken apart with something aboard drops it, and it is lost
	combat.lose_cargo(target, 0)
end

local function resolve(delta: number)
	for _, entry in pending do
		local target = state.find(entry.target_id)
		-- something another reclaimer finished off earlier this tick pays nobody a second time
		if target == nil or target.alive == false then
			continue
		end
		local applied = entry.buildpower * delta
		if target.kind == "wreck" then
			reclaim_wreck(target, applied, entry, delta)
		elseif target.kind == "reclaimable" then
			reclaim_yield(target, applied, entry, delta)
		else
			reclaim_standing(target, applied, entry, delta)
		end
	end
end

return table.freeze({
	begin_tick = begin_tick,
	request = request,
	resolve = resolve,
	can_reclaim = can_reclaim,
	target_of = target_of,
	is_reclaimed_by_ally = is_reclaimed_by_ally,
	recent_target_of = recent_target_of,
})
