-- Applying buildpower to blueprints.
--
-- A builder with buildpower B working on a blueprint costing (M metal, E energy, C buildpower)
-- pushes B buildpower per second into it and pays M/C metal and E/C energy for every point of
-- buildpower applied. A Bot Lab (B = 150) building a Grunt (M = 54, E = 900, C = 1650) therefore
-- finishes in 11s having spent about 4.9 metal/s and 82 energy/s.
--
-- Building is work (server/work.luau): paid for as it goes, with every other builder's, once the tick's work is all
-- gathered. So is repairing, which costs nothing but the buildpower.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local blueprint_decay = require(ReplicatedStorage.Shared.blueprint_decay)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)
local switches = require(ReplicatedStorage.Shared.switches)
local spots = require(ReplicatedStorage.Shared.spots)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local deaths = require(script.Parent.deaths)
local alliances = require(script.Parent.alliances)
local work = require(script.Parent.work)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity

-- How near what an upgrade is built over has to stand to its middle to be the thing it replaces: on the same spot, which
-- both were snapped to.
local UPGRADE_MATCH_RADIUS = 1
-- Blueprints somebody put buildpower into this tick, for decay to leave alone.
local fed: { [types.EntityId]: boolean } = {}

-- Finishing does not heal: max health lands on the def's full value and current health has already
-- been carried up alongside it by the flat increments below, minus whatever damage it took.
local function complete(entity: Entity)
	local def = entity.def
	entity.state = "active"
	entity.build_progress = def.buildpower_cost
	entity.metal_paid = def.metal_cost
	entity.energy_paid = def.energy_cost
	local full = unit_defs.max_health(def)
	entity.health += full - entity.max_health
	entity.max_health = full
	entity.health = math.clamp(entity.health, 1, full)

	-- Something built over another in place, a T2 mex on a T1 or an advanced geothermal on a plain one, takes it
	-- down now and refunds its metal to whoever it belonged to, as BAR's upgrade reclaimer gadgets do
	if def.upgrades ~= nil then
		for _, other in state.all() do
			if
				other.alive
				and other.state == "active"
				and spots.upgrades(def, other.def_name)
				and geometry.distance_2d(entity.position, other.position) < UPGRADE_MATCH_RADIUS
			then
				local other_def = other.def
				economy.add_metal(other.team, other_def.metal_cost)
				deaths.destroy(other, "upgraded")
				break
			end
		end
	end
end

-- `builder` puts its buildpower into `target` this tick, if it is a builder and `target` is still a blueprint.
local function request(builder: Entity, target: Entity)
	local buildpower = work.buildpower_of(builder)
	if buildpower == nil or target.state ~= "blueprint" then
		return
	end

	-- with nocost on, anything a builder touches is finished on the spot and nothing is paid
	if switches.is_on "nocost" then
		complete(target)
		return
	end

	local target_def = target.def
	local cost = target_def.buildpower_cost
	if cost <= 0 then
		return
	end

	local taken = work.take(builder, "build", target, {
		entity_id = builder.id,
		team = builder.team,
		label = `Building {target_def.display_name}`,
		rate = buildpower,
		metal_per_work = target_def.metal_cost / cost,
		energy_per_work = target_def.energy_cost / cost,
		-- never more than the blueprint has left to go
		room = function(): number?
			if target.alive == false or target.state ~= "blueprint" then
				return nil
			end
			return cost - target.build_progress
		end,
		apply = function(applied: number, metal: number, energy: number)
			target.build_progress += applied
			target.metal_paid += metal
			target.energy_paid += energy
			-- Max health tracks completion percentage, and current health moves by the same flat
			-- amount, so damage taken mid-build is never healed by further progress.
			local new_max = state.max_health_for_progress(unit_defs.max_health(target_def), target.build_progress, cost)
			target.health += new_max - target.max_health
			target.max_health = new_max
			if target.build_progress >= cost then
				complete(target)
			end
		end,
	})
	if taken then
		fed[target.id] = true
	end
end

-- Whether `builder` can repair `target`: it is a builder that repairs, and `target` is something else, finished,
-- damaged and still standing, of its own side or an ally's, that anything repairs at all (it has a build cost), and
-- that no ally is taking apart, since there is no point mending what someone is reclaiming.
local function can_repair(builder: Entity, target: Entity): boolean
	return unit_defs.does(builder.def, "repair")
		and target.alive
		and target.id ~= builder.id
		and target.state == "active"
		and target.health < target.max_health
		and alliances.are_allied(builder.team, target.team)
		and target.def.buildpower_cost > 0
		and work.worked_by_ally(target, "reclaim") == false
end

-- Repairing puts buildpower into something `can_repair` allows. Each point applied restores max_health /
-- buildpower_cost of its health, up to its full health. It costs nothing but the buildpower.
local function repair(builder: Entity, target: Entity)
	local buildpower = work.buildpower_of(builder)
	if buildpower == nil then
		return
	end
	local cost = target.def.buildpower_cost
	work.take(builder, "repair", target, {
		entity_id = builder.id,
		team = builder.team,
		label = `Repairing {target.def.display_name}`,
		rate = buildpower,
		metal_per_work = 0,
		energy_per_work = 0,
		room = function(): number?
			if target.alive == false or target.health >= target.max_health then
				return nil
			end
			return (target.max_health - target.health) / target.max_health * cost
		end,
		apply = function(applied: number)
			target.health = math.min(target.max_health, target.health + target.max_health * applied / cost)
		end,
	})
end

-- An abandoned blueprint comes apart. Once nobody has built on it for BLUEPRINT_DECAY_DELAY
-- seconds it loses BLUEPRINT_DECAY_RATE buildpower of progress a second, refunding the metal that
-- progress cost. The energy is not refunded. At no progress at all it is gone, leaving nothing.
local function decay(delta: number)
	for _, entity in state.all() do
		if entity.alive == false or entity.state ~= "blueprint" then
			continue
		end
		if fed[entity.id] then
			entity.unfed_time = 0
			continue
		end
		entity.unfed_time += delta
		if entity.unfed_time < blueprint_decay.BLUEPRINT_DECAY_DELAY then
			continue
		end

		local def = entity.def
		local lost = math.min(blueprint_decay.BLUEPRINT_DECAY_RATE * delta, entity.build_progress)
		if lost > 0 and def.buildpower_cost > 0 then
			local metal = lost * def.metal_cost / def.buildpower_cost
			economy.add_metal(entity.team, metal)
			entity.build_progress -= lost
			entity.metal_paid = math.max(0, entity.metal_paid - metal)
			entity.energy_paid = math.max(0, entity.energy_paid - lost * def.energy_cost / def.buildpower_cost)

			-- max health follows progress back down, taking current health with it by the same
			-- amount, and never far enough to kill what was only ever abandoned
			local new_max =
				state.max_health_for_progress(unit_defs.max_health(def), entity.build_progress, def.buildpower_cost)
			entity.health = math.max(1, entity.health + new_max - entity.max_health)
			entity.max_health = new_max
		end
		if entity.build_progress <= 1e-6 then
			deaths.destroy(entity, "decayed")
		end
	end
	table.clear(fed)
end

snapshot.keep("construction", function()
	return { fed = fed }
end, function(saved)
	fed = saved.fed
end)

return table.freeze({
	decay = decay,
	request = request,
	can_repair = can_repair,
	repair = repair,
})
