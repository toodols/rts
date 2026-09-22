-- The authoritative world. Everything else in src/server reads and mutates these tables; nothing
-- here knows about Roblox instances, remotes or players.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type Entity = types.Entity
type EntityId = types.EntityId
type Team = types.Team
type TeamId = types.TeamId
type EntityState = types.EntityState

local entities: { [EntityId]: Entity } = {}
-- Entities created part-way through a tick land here first. Systems iterate `entities` while a
-- factory is starting a blueprint or a death is dropping a wreck, and inserting into a table that
-- is being traversed is undefined in Lua, so new entities only join the main table at `flush`.
-- They are still reachable by id immediately, which is what construction needs within the tick.
local spawning: { [EntityId]: Entity } = {}
-- What each transport is carrying, by transport id. Something carried is inactive: it is in neither table
-- above, so nothing in the simulation sees it, shoots it, orders it or moves it, and it does nothing until it
-- is set down again. It is still drawn, hanging from its transport (`instances` reads it from here).
local holds: { [EntityId]: { Entity } } = {}
local teams: { [TeamId]: Team } = {}
local next_entity_id = 1

-- A blueprint is never at exactly zero max health, so a freshly placed one is not already dead.
local MINIMUM_BLUEPRINT_HEALTH = 1

-- A blueprint's max health is its completion percentage of the finished thing's health. Current
-- health then moves by the same flat amount whenever max health moves, which is why damage taken
-- mid-build is carried through to completion rather than healed away by further progress.
local function max_health_for_progress(full_health: number, progress: number, cost: number): number
	return math.max(MINIMUM_BLUEPRINT_HEALTH, full_health * (progress / cost))
end

local function create_team(id: TeamId): Team
	local team: Team = {
		id = id,
		-- replaced by the player's name when a player takes the team
		name = `Team {id}`,
		metal = config.STARTING_METAL,
		energy = config.STARTING_ENERGY,
		metal_income = config.METAL_INCOME,
		energy_income = config.ENERGY_INCOME,
		metal_capacity = config.METAL_CAPACITY,
		energy_capacity = config.ENERGY_CAPACITY,
		metal_revenue = 0,
		metal_expense = 0,
		energy_revenue = 0,
		energy_expense = 0,
	}
	teams[id] = team
	return team
end

local function get_team(id: TeamId): Team?
	return teams[id]
end

local function all_teams(): { [TeamId]: Team }
	return teams
end

local function create_entity(
	def_name: string,
	team: TeamId,
	position: Vector3,
	facing: number,
	state: EntityState
): Entity
	local def = unit_defs.get(def_name)
	local id = next_entity_id
	next_entity_id += 1

	local entity: Entity = {
		id = id,
		team = team,
		def_name = def_name,
		kind = def.kind,
		state = state,
		position = position,
		facing = facing,
		velocity = Vector3.zero,
		health = if state == "active" then def.health else max_health_for_progress(def.health, 0, def.buildpower_cost),
		max_health = if state == "active"
			then def.health
			else max_health_for_progress(def.health, 0, def.buildpower_cost),
		build_progress = if state == "active" then def.buildpower_cost else 0,
		metal_paid = if state == "active" then def.metal_cost else 0,
		energy_paid = if state == "active" then def.energy_cost else 0,
		orders = {},
		queue = {},
		reload_remaining = 0,
		manual_reload_remaining = 0,
		turret_reloads = {},
		burst_remaining = 0,
		turret_burst_remaining = {},
		stockpile = 0,
		stockpile_progress = 0,
		unfed_time = 0,
		wreck = nil,
		alive = true,
	}

	spawning[id] = entity
	return entity
end

-- Wrecks reuse the dead thing's def for their footprint and look, but carry their own metal and
-- buildpower pools. They belong to no team, so team 0 marks them as neutral.
local function create_wreck(source: Entity): Entity
	local def = unit_defs.get(source.def_name)
	local id = next_entity_id
	next_entity_id += 1

	-- Only finished entities ever become wrecks, so the dead thing's full costs are the right
	-- basis: 50% of its metal, over 20% of its buildpower_cost to pull back out.
	local wreck_health = math.max(1, def.health * config.WRECK_HEALTH_FRACTION)
	local metal_total = def.metal_cost * config.WRECK_METAL_FRACTION
	local buildpower_total = def.buildpower_cost * config.WRECK_BUILDPOWER_FRACTION

	local entity: Entity = {
		id = id,
		team = 0,
		def_name = source.def_name,
		kind = "wreck",
		state = "active",
		position = source.position,
		facing = source.facing,
		velocity = Vector3.zero,
		health = wreck_health,
		max_health = wreck_health,
		build_progress = 0,
		metal_paid = 0,
		energy_paid = 0,
		orders = {},
		queue = {},
		reload_remaining = 0,
		manual_reload_remaining = 0,
		turret_reloads = {},
		burst_remaining = 0,
		turret_burst_remaining = {},
		stockpile = 0,
		stockpile_progress = 0,
		unfed_time = 0,
		wreck = {
			source_def_name = source.def_name,
			metal_total = metal_total,
			metal_left = metal_total,
			buildpower_total = buildpower_total,
			buildpower_left = buildpower_total,
			resurrect_progress = 0,
		},
		alive = true,
	}

	spawning[id] = entity
	return entity
end

local function get(id: EntityId): Entity?
	local entity = entities[id]
	if entity == nil then
		entity = spawning[id]
	end
	if entity == nil then
		return nil
	end
	if entity.alive == false then
		return nil
	end
	return entity
end

-- Safe to iterate: entities created during the tick are not in here until `flush`.
local function all(): { [EntityId]: Entity }
	return entities
end

-- Moves this tick's new entities into the main table. Called once per step, after every system
-- has finished iterating.
local function flush()
	if next(spawning) == nil then
		return
	end
	for id, entity in spawning do
		entities[id] = entity
	end
	table.clear(spawning)
end

-- Takes `cargo` out of the world and into the hold of the transport `transport_id`.
local function stow(transport_id: EntityId, cargo: Entity)
	entities[cargo.id] = nil
	spawning[cargo.id] = nil
	local hold = holds[transport_id]
	if hold == nil then
		hold = {}
		holds[transport_id] = hold
	end
	table.insert(hold, cargo)
end

-- What the transport `transport_id` is carrying.
local function cargo_of(transport_id: EntityId): { Entity }
	local hold = holds[transport_id]
	if hold == nil then
		return {}
	end
	return hold
end

-- Puts `cargo` back into the world, out of the hold of `transport_id`, at `position`.
local function unstow(transport_id: EntityId, cargo: Entity, position: Vector3)
	local hold = holds[transport_id]
	if hold == nil then
		return
	end
	local index = table.find(hold, cargo)
	if index == nil then
		return
	end
	table.remove(hold, index)
	cargo.position = position
	cargo.velocity = Vector3.zero
	spawning[cargo.id] = cargo
end

-- Everything that is being carried, by any transport.
local function carried(): { Entity }
	local result = {}
	for _, hold in holds do
		for _, cargo in hold do
			table.insert(result, cargo)
		end
	end
	return result
end

-- A transport that is gone takes whatever it was carrying with it.
local function drop_hold(transport_id: EntityId)
	holds[transport_id] = nil
end

-- Entities are flagged rather than deleted mid-tick so that iteration in progress stays valid;
-- `reap` clears them out at the end of the tick.
local function mark_dead(entity: Entity)
	entity.alive = false
end

local function reap(): { EntityId }
	local removed = {}
	for id, entity in entities do
		if entity.alive == false then
			table.insert(removed, id)
			entities[id] = nil
		end
	end
	-- something can be created and killed inside the same tick, so sweep the new arrivals too
	for id, entity in spawning do
		if entity.alive == false then
			table.insert(removed, id)
			spawning[id] = nil
		end
	end
	return removed
end

return table.freeze({
	create_team = create_team,
	get_team = get_team,
	all_teams = all_teams,
	create_entity = create_entity,
	create_wreck = create_wreck,
	get = get,
	all = all,
	flush = flush,
	stow = stow,
	unstow = unstow,
	cargo_of = cargo_of,
	carried = carried,
	drop_hold = drop_hold,
	mark_dead = mark_dead,
	reap = reap,
	max_health_for_progress = max_health_for_progress,
})
