-- Resurrection: a wreck brought back as the unit or building it was.
--
-- A wreck has to be full of metal before anything can be done to raise it. One that has been reclaimed
-- from is refilled first: the resurrecting unit puts its buildpower into it and the team pays back the
-- metal that was taken, at the rate reclaiming took it. Only then does the buildpower go into the
-- resurrection itself, which takes as much as building the unit did and costs its energy but no metal,
-- the wreck having supplied that. When it is done the wreck is gone and the thing stands in its place,
-- on the team that raised it, with part of its health, and every rezzer that raised it goes on to repair it
-- to full before whatever else it was told to do.
--
-- Either is work (server/work.luau), paid for as it goes with every other builder's once the tick's work is gathered.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)
local deaths = require(script.Parent.deaths)
local work = require(script.Parent.work)

type Entity = types.Entity

-- Metal left short of full by less than this counts as full, so that rounding cannot hold a wreck back.
local FULL_TOLERANCE = 1e-6
-- How much of its health what is raised comes back with.
local RESURRECT_HEALTH_FRACTION = 0.5

-- Whether `wreck` can be raised at all: units and buildings come back, as in BAR, where a building's corpse can be
-- raised like a unit's.
local function raisable(wreck: types.Wreck): boolean
	local kind = unit_defs.get(wreck.source_def_name).kind
	return kind == "unit" or kind == "building"
end

local function can_resurrect(rezzer: Entity, target: Entity): boolean
	if unit_defs.does(rezzer.def, "resurrect") == false or rezzer.state ~= "active" then
		return false
	end
	local wreck = target.wreck
	return wreck ~= nil and raisable(wreck)
end

-- Raising, for whatever raises a wreck: a rezzer's work (`request`), and the scavengers' beacons ---------------------

-- Puts `amount` of work, no more than is left, into raising `wreck`, and returns whether it is done. It takes as much
-- as building what it was did.
local function put_work(wreck: types.Wreck, amount: number): boolean
	local cost = unit_defs.get(wreck.source_def_name).buildpower_cost
	wreck.resurrect_progress += math.min(amount, cost - wreck.resurrect_progress)
	return wreck.resurrect_progress >= cost - FULL_TOLERANCE
end

-- The wreck `target` (whose `wreck` is `wreck`) stands up again as what it was, on team `team`, with
-- RESURRECT_HEALTH_FRACTION of its health, and the wreck is gone. Returns what stands.
local function raise(target: Entity, wreck: types.Wreck, team: types.TeamId): Entity
	local raised = state.create_entity(wreck.source_def_name, team, target.position, target.facing, "active")
	raised.health = raised.max_health * RESURRECT_HEALTH_FRACTION
	deaths.destroy(target, "removed")
	return raised
end

---------------------------------------------------------------------------------------------------------------------

-- Gives every rezzer that worked on the wreck `wreck_id` this tick, and can repair, a repair order on `raised`, the
-- order a player's repair gives, ahead of whatever it was told to do after: in place of the finished resurrect order
-- when that is the one it is on, as it usually is, or before whatever it is on otherwise, which it takes up again
-- once the thing is whole.
local function repair_after(wreck_id: types.EntityId, raised: Entity)
	if raised.health >= raised.max_health then
		return
	end
	for _, rezzer in work.workers_on(wreck_id, "resurrect") do
		if rezzer.alive == false or unit_defs.does(rezzer.def, "repair") == false then
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

-- The wreck `target` stands up again as what it was, on `team`.
local function complete(target: Entity, wreck: types.Wreck, team: types.TeamId)
	repair_after(target.id, raise(target, wreck, team))
end

-- `rezzer` puts its buildpower into raising `target` this tick, if it can: into refilling it with the metal taken out
-- of it, paying that back, while it is short of any, and otherwise into raising it, paying its energy.
local function request(rezzer: Entity, target: Entity)
	local buildpower = work.buildpower_of(rezzer)
	local wreck = target.wreck
	local yield = target.yield
	if buildpower == nil or wreck == nil or yield == nil or can_resurrect(rezzer, target) == false then
		return
	end
	local team = rezzer.team
	local source = unit_defs.get(wreck.source_def_name)
	local function present(): boolean
		return target.alive and state.get(target.id) ~= nil
	end

	if yield.buildpower_left < yield.buildpower_total - FULL_TOLERANCE then
		work.take(rezzer, "resurrect", target, {
			entity_id = rezzer.id,
			team = team,
			label = `Refilling {target.def.display_name}`,
			rate = buildpower,
			metal_per_work = yield.metal_total / yield.buildpower_total,
			energy_per_work = 0,
			room = function(): number?
				return if present() then yield.buildpower_total - yield.buildpower_left else nil
			end,
			apply = function(restored: number, metal: number)
				yield.buildpower_left = math.min(yield.buildpower_total, yield.buildpower_left + restored)
				yield.metal_left = math.min(yield.metal_total, yield.metal_left + metal)
				if yield.buildpower_left >= yield.buildpower_total - FULL_TOLERANCE then
					yield.buildpower_left = yield.buildpower_total
					yield.metal_left = yield.metal_total
				end
			end,
		})
		return
	end

	if source.buildpower_cost <= 0 then
		complete(target, wreck, team)
		return
	end
	work.take(rezzer, "resurrect", target, {
		entity_id = rezzer.id,
		team = team,
		label = `Raising {source.display_name}`,
		rate = buildpower,
		metal_per_work = 0,
		energy_per_work = source.energy_cost / source.buildpower_cost,
		room = function(): number?
			return if present() then source.buildpower_cost - wreck.resurrect_progress else nil
		end,
		apply = function(step: number)
			if put_work(wreck, step) then
				complete(target, wreck, team)
			end
		end,
	})
end

return table.freeze({
	RESURRECT_HEALTH_FRACTION = RESURRECT_HEALTH_FRACTION,
	request = request,
	can_resurrect = can_resurrect,
	raisable = raisable,
	put_work = put_work,
	raise = raise,
})
