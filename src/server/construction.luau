-- Applying buildpower to blueprints.
--
-- A builder with buildpower B working on a blueprint costing (M metal, E energy, C buildpower)
-- pushes B buildpower per second into it and pays M/C metal and E/C energy for every point of
-- buildpower applied. A Bot Lab (B = 150) building a Grunt (M = 54, E = 900, C = 1650) therefore
-- finishes in 11s having spent about 4.9 metal/s and 82 energy/s.
--
-- Builders register their intent during the tick and the whole batch is settled at the end, so
-- that when a team cannot afford everything at once the shortfall is spread proportionally across
-- every drain instead of being won by whichever builder happened to run first.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local geometry = require(ReplicatedStorage.Shared.geometry)

local state = require(script.Parent.state)
local economy = require(script.Parent.economy)
local nocost = require(script.Parent.nocost)
local flows = require(script.Parent.flows)

type Entity = types.Entity
type Drain = types.Drain
type TeamId = types.TeamId

local pending: { Drain } = {}
-- Who worked on what, this tick and the one before. Guarding builders read these while the tick is
-- still being assembled, when a builder later in the order may not have registered yet, so the
-- previous tick is what makes the answer independent of iteration order.
local working: { [types.EntityId]: types.EntityId } = {}
-- Who repaired what this tick, so the client can show it.
local repairing: { [types.EntityId]: types.EntityId } = {}
-- Blueprints somebody put buildpower into this tick, for decay to leave alone.
local fed: { [types.EntityId]: boolean } = {}
local previous_working: { [types.EntityId]: types.EntityId } = {}

local function begin_tick()
	table.clear(pending)
	table.clear(fed)
	table.clear(repairing)
	previous_working, working = working, previous_working
	table.clear(working)
end

-- Finishing does not heal: max health lands on the def's full value and current health has already
-- been carried up alongside it by the flat increments below, minus whatever damage it took.
local function complete(entity: Entity)
	local def = unit_defs.of(entity)
	entity.state = "active"
	entity.build_progress = def.buildpower_cost
	entity.metal_paid = def.metal_cost
	entity.energy_paid = def.energy_cost
	entity.health += def.health - entity.max_health
	entity.max_health = def.health
	entity.health = math.clamp(entity.health, 1, def.health)

	-- Something built over another in place, a T2 mex on a T1 or an advanced geothermal on a plain one, takes it
	-- down now and refunds its metal to whoever it belonged to, as BAR's upgrade reclaimer gadgets do
	if def.upgrades ~= nil then
		for _, other in state.all() do
			if
				other.alive
				and other.state == "active"
				and table.find(def.upgrades, other.def_name) ~= nil
				and geometry.distance_2d(entity.position, other.position) < 1
			then
				local other_def = unit_defs.of(other)
				economy.add_metal(other.team, other_def.metal_cost)
				state.mark_dead(other)
				break
			end
		end
	end
end

-- Registers `builder` as working on `target` for this tick. Does nothing if the builder has no
-- buildpower or the target is already finished.
local function request(builder: Entity, target: Entity)
	local builder_def = unit_defs.of(builder)
	local buildpower = builder_def.buildpower
	if buildpower == nil then
		return
	end
	if target.state ~= "blueprint" then
		return
	end

	-- with nocost on, anything a builder touches is finished on the spot and nothing is paid
	if nocost.is_enabled() then
		complete(target)
		return
	end

	local target_def = unit_defs.of(target)
	local cost = target_def.buildpower_cost
	if cost <= 0 then
		return
	end

	working[builder.id] = target.id
	fed[target.id] = true
	table.insert(pending, {
		entity_id = builder.id,
		team = builder.team,
		target_id = target.id,
		buildpower = buildpower,
		metal_per_buildpower = target_def.metal_cost / cost,
		energy_per_buildpower = target_def.energy_cost / cost,
	})
end

-- What `builder` put its buildpower into this tick, if it is still unfinished. Read after the step
-- to show which builders are working and on what; the list is only cleared at the next tick.
local function target_of(builder_id: types.EntityId): types.EntityId?
	for _, drain in pending do
		if drain.entity_id ~= builder_id then
			continue
		end
		local target = state.get(drain.target_id)
		if target ~= nil and target.alive and target.state == "blueprint" then
			return target.id
		end
	end
	return nil
end

-- Repairing puts buildpower into something finished and damaged. Each point applied restores
-- max_health / buildpower_cost of its health. It costs nothing but the buildpower.
local function repair(builder: Entity, target: Entity, delta: number)
	local builder_def = unit_defs.of(builder)
	local buildpower = builder_def.buildpower
	if buildpower == nil or builder_def.repairing == false then
		return
	end
	if target.alive == false or target.kind == "wreck" or target.state ~= "active" then
		return
	end
	if target.health >= target.max_health then
		return
	end
	local target_def = unit_defs.of(target)
	if target_def.buildpower_cost <= 0 then
		return
	end

	repairing[builder.id] = target.id
	local fraction = math.min(
		buildpower * delta / target_def.buildpower_cost,
		(target.max_health - target.health) / target.max_health
	)
	target.health = math.min(target.max_health, target.health + target.max_health * fraction)
end

-- What `builder_id` repaired this tick, if anything.
local function repair_target_of(builder_id: types.EntityId): types.EntityId?
	return repairing[builder_id]
end

-- The blueprint `builder_id` worked on this tick or last, if it is still unfinished.
local function recent_target_of(builder_id: types.EntityId): types.EntityId?
	local target_id = working[builder_id]
	if target_id == nil then
		target_id = previous_working[builder_id]
	end
	if target_id == nil then
		return nil
	end
	local target = state.get(target_id)
	if target ~= nil and target.alive and target.state == "blueprint" then
		return target.id
	end
	return nil
end

-- Settles every drain registered this tick.
local function resolve(delta: number)
	if #pending == 0 then
		return
	end

	local metal_demand: { [TeamId]: number } = {}
	local energy_demand: { [TeamId]: number } = {}

	for _, drain in pending do
		local buildpower = drain.buildpower * delta
		metal_demand[drain.team] = (metal_demand[drain.team] or 0) + buildpower * drain.metal_per_buildpower
		energy_demand[drain.team] = (energy_demand[drain.team] or 0) + buildpower * drain.energy_per_buildpower
	end

	-- One scale per team: the fraction of this tick's demand the team can actually pay for.
	local scale: { [TeamId]: number } = {}
	-- what holds a team's builders back when it cannot pay for all of it
	local short_of: { [TeamId]: flows.Stall } = {}
	for team_id, metal_wanted in metal_demand do
		local team = state.get_team(team_id)
		if team == nil then
			scale[team_id] = 0
			continue
		end
		local factor = 1
		if metal_wanted > 0 and team.metal / metal_wanted < factor then
			factor = team.metal / metal_wanted
			short_of[team_id] = "metal"
		end
		local energy_wanted = energy_demand[team_id] or 0
		if energy_wanted > 0 and team.energy / energy_wanted < factor then
			factor = team.energy / energy_wanted
			short_of[team_id] = "energy"
		end
		scale[team_id] = math.clamp(factor, 0, 1)
	end

	for _, drain in pending do
		local team = state.get_team(drain.team)
		local target = state.get(drain.target_id)
		if team == nil or target == nil or target.state ~= "blueprint" then
			continue
		end

		if scale[drain.team] < 1 then
			flows.stall(drain.entity_id, short_of[drain.team])
		end

		local target_def = unit_defs.of(target)
		local applied = drain.buildpower * delta * scale[drain.team]
		-- never overshoot the blueprint's remaining cost
		applied = math.min(applied, target_def.buildpower_cost - target.build_progress)
		if applied <= 0 then
			continue
		end

		local metal = applied * drain.metal_per_buildpower
		local energy = applied * drain.energy_per_buildpower
		flows.add(drain.entity_id, `Building {target_def.display_name}`, -metal / delta, -energy / delta)

		team.metal = math.max(0, team.metal - metal)
		team.energy = math.max(0, team.energy - energy)
		economy.record_spent(drain.team, metal, energy)

		target.build_progress += applied
		target.metal_paid += metal
		target.energy_paid += energy

		-- Max health tracks completion percentage, and current health moves by the same flat
		-- amount, so damage taken mid-build is never healed by further progress.
		local new_max =
			state.max_health_for_progress(target_def.health, target.build_progress, target_def.buildpower_cost)
		target.health += new_max - target.max_health
		target.max_health = new_max

		if target.build_progress >= target_def.buildpower_cost then
			complete(target)
		end
	end
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
		if entity.unfed_time < config.BLUEPRINT_DECAY_DELAY then
			continue
		end

		local def = unit_defs.of(entity)
		local lost = math.min(config.BLUEPRINT_DECAY_RATE * delta, entity.build_progress)
		if lost > 0 and def.buildpower_cost > 0 then
			local metal = lost * def.metal_cost / def.buildpower_cost
			economy.add_metal(entity.team, metal)
			entity.build_progress -= lost
			entity.metal_paid = math.max(0, entity.metal_paid - metal)
			entity.energy_paid = math.max(0, entity.energy_paid - lost * def.energy_cost / def.buildpower_cost)

			-- max health follows progress back down, taking current health with it by the same
			-- amount, and never far enough to kill what was only ever abandoned
			local new_max = state.max_health_for_progress(def.health, entity.build_progress, def.buildpower_cost)
			entity.health = math.max(1, entity.health + new_max - entity.max_health)
			entity.max_health = new_max
		end
		if entity.build_progress <= 1e-6 then
			state.mark_dead(entity)
		end
	end
end

return table.freeze({
	begin_tick = begin_tick,
	decay = decay,
	request = request,
	resolve = resolve,
	complete = complete,
	target_of = target_of,
	repair = repair,
	repair_target_of = repair_target_of,
	recent_target_of = recent_target_of,
})
