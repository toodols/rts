-- Reclaiming: buildpower run backwards. The same buildpower that would have built a thing tears
-- it down, paying out metal at the same metal-per-buildpower rate construction charges.
--
-- A wreck has its own pools (50% of the dead unit's metal over 20% of its buildpower_cost), so
-- reclaiming a wreck is much faster than rebuilding the unit was. Reclaiming something still
-- standing unwinds its build progress and refunds metal at its own build rate. A reclaimable, a rock or a
-- tree, is taken apart exactly as a wreck is, out of the pools its def gives it, and pays out energy as
-- well as metal.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local alliances = require(script.Parent.alliances)

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
	local def = unit_defs.get(reclaimer.def_name)
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
		and unit_defs.get(target.def_name).reclaimable == false
	then
		return false
	end
	return true
end

local function request(reclaimer: Entity, target: Entity)
	local def = unit_defs.get(reclaimer.def_name)
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
		local target = state.get(entry.target_id)
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
	local target = state.get(target_id)
	if target ~= nil and target.alive then
		return target.id
	end
	return nil
end

local function reclaim_wreck(target: Entity, applied: number, team: types.TeamId)
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
	economy.add_metal(team, metal)

	if wreck.buildpower_left <= 0 then
		state.mark_dead(target)
	end
end

-- A reclaimable pays out its metal and energy in step with the buildpower put into it, at the rates its def's
-- metal_cost and energy_cost over its buildpower_cost set, and is gone once all of that has been put in.
local function reclaim_yield(target: Entity, applied: number, team: types.TeamId)
	local yield = target.yield
	if yield == nil then
		return
	end
	local def = unit_defs.get(target.def_name)
	if def.buildpower_cost <= 0 then
		economy.add_metal(team, yield.metal_left)
		economy.add_energy(team, yield.energy_left)
		state.mark_dead(target)
		return
	end

	local consumed = math.min(applied, yield.buildpower_left)
	local metal = math.min(yield.metal_left, consumed * def.metal_cost / def.buildpower_cost)
	local energy = math.min(yield.energy_left, consumed * def.energy_cost / def.buildpower_cost)

	yield.buildpower_left -= consumed
	yield.metal_left -= metal
	yield.energy_left -= energy
	economy.add_metal(team, metal)
	economy.add_energy(team, energy)

	if yield.buildpower_left <= 0 then
		state.mark_dead(target)
	end
end

-- Reclaiming something still standing takes its health away at the rate its buildpower cost sets:
-- each point of buildpower applied removes that fraction of its max health, so a reclaimer of
-- buildpower B strips a target of cost C in C / B seconds however hurt it was. When its health runs
-- out it is gone, leaving no wreck, and its metal goes to the reclaimer that finished it. A blueprint
-- counts for the buildpower actually put into it, and pays back the metal actually spent on it.
local function reclaim_standing(target: Entity, applied: number, team: types.TeamId)
	local def = unit_defs.get(target.def_name)
	local is_blueprint = target.state == "blueprint"
	local cost = if is_blueprint then target.build_progress else def.buildpower_cost

	if cost > 0 then
		target.health -= target.max_health * applied / cost
		if target.health > 0 then
			return
		end
	end

	economy.add_metal(team, if is_blueprint then target.metal_paid else def.metal_cost)
	state.mark_dead(target)
end

local function resolve(delta: number)
	for _, entry in pending do
		local target = state.get(entry.target_id)
		-- something another reclaimer finished off earlier this tick pays nobody a second time
		if target == nil or target.alive == false then
			continue
		end
		local applied = entry.buildpower * delta
		if target.kind == "wreck" then
			reclaim_wreck(target, applied, entry.team)
		elseif target.kind == "reclaimable" then
			reclaim_yield(target, applied, entry.team)
		else
			reclaim_standing(target, applied, entry.team)
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
