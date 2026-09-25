-- Resurrection: a wreck brought back as the unit or building it was.
--
-- A wreck has to be full of metal before anything can be done to raise it. One that has been reclaimed
-- from is refilled first: the resurrecting unit puts its buildpower into it and the team pays back the
-- metal that was taken, at the rate reclaiming took it. Only then does the buildpower go into the
-- resurrection itself, which takes as much as building the unit did and costs its energy but no metal,
-- the wreck having supplied that. When it is done the wreck is gone and the thing stands in its place,
-- on the team that raised it, with part of its health, and every rezzer that raised it goes on to repair it
-- to full before whatever else it was told to do.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)

type Entity = types.Entity

type Request = {
	rezzer_id: types.EntityId,
	team: types.TeamId,
	target_id: types.EntityId,
	buildpower: number,
}

-- Metal left short of full by less than this counts as full, so that rounding cannot hold a wreck back.
local FULL_TOLERANCE = 1e-6

local pending: { Request } = {}

local function begin_tick()
	table.clear(pending)
end

local function can_resurrect(rezzer: Entity, target: Entity): boolean
	local def = unit_defs.of(rezzer)
	if def.resurrecting == false or def.buildpower == nil or rezzer.state ~= "active" then
		return false
	end
	local wreck = target.wreck
	if target.kind ~= "wreck" or wreck == nil then
		return false
	end
	-- units and buildings come back, as in BAR, where a building's corpse can be raised like a unit's
	local kind = unit_defs.get(wreck.source_def_name).kind
	return kind == "unit" or kind == "building"
end

local function request(rezzer: Entity, target: Entity)
	local buildpower = unit_defs.of(rezzer).buildpower
	if buildpower == nil or can_resurrect(rezzer, target) == false then
		return
	end
	table.insert(pending, {
		rezzer_id = rezzer.id,
		team = rezzer.team,
		target_id = target.id,
		buildpower = buildpower,
	})
end

-- The wreck `rezzer_id` worked on this tick, if it is still there. Read after the step.
local function target_of(rezzer_id: types.EntityId): types.EntityId?
	for _, entry in pending do
		if entry.rezzer_id == rezzer_id then
			local target = state.get(entry.target_id)
			if target ~= nil and target.alive then
				return target.id
			end
		end
	end
	return nil
end

-- Puts back the metal a wreck has lost, at the rate reclaiming took it out, and pays for it. It stalls
-- while the team cannot pay.
local function refill(wreck: types.Wreck, applied: number, team: types.TeamId)
	local missing = wreck.buildpower_total - wreck.buildpower_left
	local restored = math.min(applied, missing)
	local metal = restored * wreck.metal_total / wreck.buildpower_total
	if economy.try_spend(team, metal, 0) == false then
		return
	end
	wreck.buildpower_left = math.min(wreck.buildpower_total, wreck.buildpower_left + restored)
	wreck.metal_left = math.min(wreck.metal_total, wreck.metal_left + metal)
	if wreck.buildpower_left >= wreck.buildpower_total - FULL_TOLERANCE then
		wreck.buildpower_left = wreck.buildpower_total
		wreck.metal_left = wreck.metal_total
	end
end

-- Gives every rezzer that worked on the wreck `wreck_id` this tick, and can repair, a repair order on `raised`, the
-- order a player's repair gives, ahead of whatever it was told to do after: in place of the finished resurrect order
-- when that is the one it is on, as it usually is, or before whatever it is on otherwise, which it takes up again
-- once the thing is whole.
local function repair_after(wreck_id: types.EntityId, raised: Entity)
	if raised.health >= raised.max_health then
		return
	end
	for _, entry in pending do
		if entry.target_id ~= wreck_id then
			continue
		end
		local rezzer = state.get(entry.rezzer_id)
		if rezzer == nil or unit_defs.of(rezzer).repairing == false then
			continue
		end
		local repair: types.Order = { kind = "repair", position = raised.position, target_id = raised.id }
		local first = rezzer.orders[1]
		if first ~= nil and first.kind == "resurrect" and first.target_id == wreck_id then
			rezzer.orders[1] = repair
		else
			table.insert(rezzer.orders, 1, repair)
		end
	end
end

local function complete(target: Entity, wreck: types.Wreck, team: types.TeamId)
	local raised = state.create_entity(wreck.source_def_name, team, target.position, target.facing, "active")
	raised.health = raised.max_health * config.RESURRECT_HEALTH_FRACTION
	state.mark_dead(target)
	repair_after(target.id, raised)
end

local function resolve(delta: number)
	for _, entry in pending do
		local target = state.get(entry.target_id)
		-- one another rezzer finished earlier this tick is gone
		if target == nil or target.alive == false then
			continue
		end
		local wreck = target.wreck
		if wreck == nil then
			continue
		end
		local applied = entry.buildpower * delta

		if wreck.buildpower_left < wreck.buildpower_total - FULL_TOLERANCE then
			refill(wreck, applied, entry.team)
			continue
		end

		local source = unit_defs.get(wreck.source_def_name)
		if source.buildpower_cost <= 0 then
			complete(target, wreck, entry.team)
			continue
		end
		local step = math.min(applied, source.buildpower_cost - wreck.resurrect_progress)
		local energy = source.energy_cost * step / source.buildpower_cost
		if economy.try_spend(entry.team, 0, energy) == false then
			continue
		end
		wreck.resurrect_progress += step
		if wreck.resurrect_progress >= source.buildpower_cost - FULL_TOLERANCE then
			complete(target, wreck, entry.team)
		end
	end
end

return table.freeze({
	begin_tick = begin_tick,
	request = request,
	resolve = resolve,
	can_resurrect = can_resurrect,
	target_of = target_of,
})
