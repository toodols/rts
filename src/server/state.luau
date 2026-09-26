-- The authoritative world. Everything else in src/server reads and mutates these tables; nothing
-- here knows about Roblox instances, remotes or players.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local signal = require(ReplicatedStorage.Shared.signal)
local teams = require(ReplicatedStorage.Shared.teams)
local skins = require(ReplicatedStorage.Shared.skins)

local economy_settings = require(script.Parent.economy_settings)
local snapshot = require(script.Parent.snapshot)

type Entity = types.Entity
type EntityId = types.EntityId
type Team = types.Team
type TeamId = types.TeamId
type EntityState = types.EntityState

-- The fraction of a reclaimable's buildpower, its def's or its map's, that reclaiming it takes: a rock or a tree is
-- quick work, so clearing ground does not tie a builder up
local RECLAIMABLE_BUILDPOWER_FRACTION = 0.1

local entities: { [EntityId]: Entity } = {}
-- Entities created during a step land here first. Systems iterate `entities` while a factory is starting a blueprint or
-- a death is dropping a wreck, and inserting into a table that is being traversed is undefined in Lua, so what a step
-- makes only joins the main table at the step's own point for it, once the dead are cleared (`flush`). It is still
-- reachable by id at once (`get`), and whatever asks what stands where sees it (`pending`). Outside a step nothing is
-- iterating the world, and what is made joins it at once (`admit`).
local spawning: { [EntityId]: Entity } = {}
-- Whether a step is running (`begin_step`, `end_step`).
local stepping = false
-- Seconds of game played: the game's own clock, which runs only as the simulation steps (`now`).
local elapsed = 0
-- What each transport is carrying, by transport id. Something carried is inactive: it is in neither table
-- above, so it does nothing, takes no orders and is not moved until it is set down again. It is still drawn,
-- hanging from its transport (`instances` reads it from here), and it can still be shot at and reclaimed, which
-- is why `get` looks in here when asked to.
local holds: { [EntityId]: { Entity } } = {}
-- The transport each carried thing is in, by the carried thing's id.
local carriers: { [EntityId]: EntityId } = {}
local team_records: { [TeamId]: Team } = {}
local next_entity_id = 1
-- see `world_version`
local membership = 0

-- Indexes of what in the world has something its def says, each kept as things join and leave it (`index`), so that
-- a part of the game that only ever looks at those does not walk everything there is to find them.
type Index = {
	has: (types.EntityDef) -> boolean,
	members: { [EntityId]: Entity },
}
local indexes: { Index } = {}

-- `entity` is in the world now: in `entities`, and in every index it belongs in.
local function join(entity: Entity)
	entities[entity.id] = entity
	for _, index in indexes do
		if index.has(entity.def) then
			index.members[entity.id] = entity
		end
	end
end

-- The entity `id` has left the world.
local function leave(id: EntityId)
	entities[id] = nil
	for _, index in indexes do
		index.members[id] = nil
	end
end

-- `entity`, just made or set down, joins the world: at once outside a step, and at the step's `flush` during one.
local function admit(entity: Entity)
	if stepping then
		spawning[entity.id] = entity
	else
		join(entity)
		membership += 1
	end
end

-- Everything in the world whose def `has` something, by id, kept up to date from now on: the dead among it until the
-- step clears them away, as in `all`. Its order is no order at all, so it is only for what does the same to each
-- whatever order they come in. Asked for once, as a module loads.
local function indexed(has: (types.EntityDef) -> boolean): { [EntityId]: Entity }
	local made: Index = { has = has, members = {} }
	for id, entity in entities do
		if has(entity.def) then
			made.members[id] = entity
		end
	end
	table.insert(indexes, made)
	return made.members
end

-- A blueprint is never at exactly zero max health, so a freshly placed one is not already dead.
local MINIMUM_BLUEPRINT_HEALTH = 1

-- A blueprint's max health is its completion percentage of the finished thing's health. Current
-- health then moves by the same flat amount whenever max health moves, which is why damage taken
-- mid-build is carried through to completion rather than healed away by further progress.
local function max_health_for_progress(full_health: number, progress: number, cost: number): number
	return math.max(MINIMUM_BLUEPRINT_HEALTH, full_health * (progress / cost))
end

-- A team as it starts: a stockpile, the capacity to hold it and an income.
local function fresh_team(id: TeamId): Team
	return {
		id = id,
		-- replaced by the player's name when a player takes the team
		name = `Team {id}`,
		skin = skins.DEFAULT_SKIN,
		metal = economy_settings.STARTING_METAL,
		energy = economy_settings.STARTING_ENERGY,
		metal_income = economy_settings.METAL_INCOME,
		energy_income = economy_settings.ENERGY_INCOME,
		metal_capacity = economy_settings.METAL_CAPACITY,
		energy_capacity = economy_settings.ENERGY_CAPACITY,
		metal_revenue = 0,
		metal_expense = 0,
		energy_revenue = 0,
		energy_expense = 0,
	}
end

local function create_team(id: TeamId): Team
	local team = fresh_team(id)
	team_records[id] = team
	return team
end

-- Puts a team back to how it started, in place, keeping its name and its skin.
local function reset_team(id: TeamId)
	local team = team_records[id]
	if team == nil then
		return
	end
	local fresh = fresh_team(id)
	fresh.name = team.name
	fresh.skin = team.skin
	for key, value in fresh :: { [string]: any } do
		(team :: any)[key] = value
	end
end

-- Takes a team out of the game, its record and all. Only for a team with nothing left on the field.
local function remove_team(id: TeamId)
	team_records[id] = nil
end

local function get_team(id: TeamId): Team?
	return team_records[id]
end

local function all_teams(): { [TeamId]: Team }
	return team_records
end

-- An entity of `def`, which it is drawn as `def_name`, with nothing done to it yet: finished, whole, idle, credited with
-- nothing. Every kind of entity starts from this, and each constructor below sets what is its own.
local function blank_entity(
	def_name: string,
	def: types.EntityDef,
	team: TeamId,
	position: Vector3,
	facing: number,
	health: number
): Entity
	local id = next_entity_id
	next_entity_id += 1
	return {
		id = id,
		team = team,
		def_name = def_name,
		skin = nil,
		def = def,
		kind = def.kind,
		state = "active",
		position = position,
		facing = facing,
		velocity = Vector3.zero,
		health = health,
		max_health = health,
		build_progress = 0,
		metal_paid = 0,
		energy_paid = 0,
		orders = {},
		queue = {},
		manual_reload_remaining = 0,
		weapon_reloads = {},
		weapon_burst_remaining = {},
		weapon_stockpiles = {},
		drone_stockpile = nil,
		weapon_aims = {},
		unfed_time = 0,
		wreck = nil,
		yield = nil,
		kills = 0,
		damage_dealt = 0,
		score_dealt = 0,
		experience = 0,
		emp = 0,
		alive = true,
	}
end

-- Told of every unit and building as it is made (not wrecks or reclaimables).
local created = signal.new() :: signal.Signal<Entity>

local function create_entity(
	def_name: string,
	team: TeamId,
	position: Vector3,
	facing: number,
	state: EntityState
): Entity
	-- it wears its team's skin, and a neutral thing, whose team is not a real one, the default
	local owner = team_records[team]
	local skin = if owner ~= nil then owner.skin else skins.DEFAULT_SKIN
	local def = unit_defs.skinned(def_name, skin)
	local finished = state == "active"
	local entity = blank_entity(
		def_name,
		def,
		team,
		position,
		facing,
		if finished
			then unit_defs.max_health(def)
			else max_health_for_progress(unit_defs.max_health(def), 0, def.buildpower_cost)
	)
	entity.skin = skin
	entity.state = state
	entity.build_progress = if finished then def.buildpower_cost else 0
	entity.metal_paid = if finished then def.metal_cost else 0
	entity.energy_paid = if finished then def.energy_cost else 0
	-- each weapon starts loaded, out of burst and with no missiles yet, and a carrier with no drones in reserve
	for index, weapon in def.weapons or {} do
		entity.weapon_reloads[index] = 0
		entity.weapon_burst_remaining[index] = 0
		if weapon.stockpile ~= nil then
			entity.weapon_stockpiles[index] = { held = 0, progress = 0 }
		end
	end
	if def.carrier ~= nil then
		entity.drone_stockpile = { held = 0, progress = 0 }
	end

	admit(entity)
	created.fire(entity)
	return entity
end

-- Remains of `def`, which it is drawn as `def_name`, lying at `position` turned to `facing` and holding `amounts`: a wreck
-- or a reclaimable. They belong to nobody, so they are on the neutral team, and wear no skin whatever made them.
local function create_remains(
	def_name: string,
	def: types.EntityDef,
	position: Vector3,
	facing: number,
	amounts: types.Holds
): Entity
	local entity = blank_entity(def_name, def, teams.NEUTRAL, position, facing, unit_defs.max_health(def))
	entity.yield = {
		metal_total = amounts.metal,
		energy_total = amounts.energy,
		buildpower_total = amounts.buildpower,
		metal_left = amounts.metal,
		energy_left = amounts.energy,
		buildpower_left = amounts.buildpower,
	}
	admit(entity)
	return entity
end

-- The wreck of a finished `def_name` that stood at `position`, turned to `facing`: its own def (`unit_defs.wreck_of`),
-- full of what that says. Only finished entities ever become wrecks, so the dead thing's full costs are the right basis.
local function create_wreck(def_name: string, position: Vector3, facing: number): Entity
	local def = unit_defs.wreck_of(def_name)
	local entity = create_remains(def_name, def, position, facing, {
		metal = def.metal_cost,
		energy = def.energy_cost,
		buildpower = def.buildpower_cost,
	})
	entity.wreck = { source_def_name = def_name, resurrect_progress = 0 }
	return entity
end

-- A reclaimable, a rock or a tree, lying at `position`: full of what `amounts` says, or what its def does.
local function create_reclaimable(def_name: string, position: Vector3, facing: number, amounts: types.Holds?): Entity
	local def = unit_defs.get(def_name)
	assert(def.kind == "reclaimable", `"{def_name}" is not a reclaimable`)
	local full = amounts or { metal = def.metal_cost, energy = def.energy_cost, buildpower = def.buildpower_cost }
	return create_remains(def_name, def, position, facing, {
		metal = full.metal,
		energy = full.energy,
		buildpower = full.buildpower * RECLAIMABLE_BUILDPOWER_FRACTION,
	})
end

-- The living entity `id`, if there is one: in the world, or just made this tick and about to join it. Something
-- hanging from a transport is out of the world, and is only found with `include_carried`, for what it can still be:
-- shot at and reclaimed where it hangs.
local function get(id: EntityId, include_carried: boolean?): Entity?
	local entity = entities[id]
	if entity == nil then
		entity = spawning[id]
	end
	if entity == nil and include_carried == true then
		local transport_id = carriers[id]
		if transport_id ~= nil then
			for _, cargo in holds[transport_id] do
				if cargo.id == id then
					entity = cargo
					break
				end
			end
		end
	end
	if entity == nil or entity.alive == false then
		return nil
	end
	return entity
end

-- Whether `entity` is something standing on the map, anyone's: living, and not remains lying about.
local function is_present(entity: Entity): boolean
	return entity.alive and unit_defs.is_remains(entity.def) == false
end

-- Safe to iterate: entities created since they last joined the world are not in here (`pending`).
local function all(): { [EntityId]: Entity }
	return entities
end

-- What the step has made and has not joined the world yet, by id. Read only: whatever asks what stands where
-- (placement, a builder's blueprint on its site) looks through it too.
local function pending(): { [EntityId]: Entity }
	return spawning
end

-- A step `delta` seconds long begins (server/simulation.luau): the game's clock moves on to its end, and from now until
-- it ends (`end_step`) whatever is made waits to join the world.
local function begin_step(delta: number)
	stepping = true
	elapsed += delta
end

-- Seconds of game played so far, by the end of the step being run: what everything in the game times itself by, rather
-- than the wall clock, so that a paused game, a warped one and a headless one all keep the game's own time.
local function now(): number
	return elapsed
end

-- The step's own point for what it made to join the world, once the dead are cleared and nothing is iterating it. Only
-- the step flushes: outside one, what is made has joined already.
local function flush()
	assert(stepping, "only a step flushes what it made")
	if next(spawning) == nil then
		return
	end
	for _, entity in spawning do
		join(entity)
	end
	table.clear(spawning)
	membership += 1
end

-- The step is over: what its last phases made joins the world, and from now on what is made joins it at once.
local function end_step()
	flush()
	stepping = false
end

-- A count that goes up whenever something joins or leaves the world, for what indexes it to tell it has changed.
local function world_version(): number
	return membership
end

-- Everything that is being carried, by any transport, worked out again only after a hold has changed. Read only.
local carried_list: { Entity }? = nil

-- Takes `cargo` out of the world and into the hold of the transport `transport_id`.
local function stow(transport_id: EntityId, cargo: Entity)
	leave(cargo.id)
	spawning[cargo.id] = nil
	local hold = holds[transport_id]
	if hold == nil then
		hold = {}
		holds[transport_id] = hold
	end
	table.insert(hold, cargo)
	carriers[cargo.id] = transport_id
	carried_list = nil
end

-- The transport `id` is being carried in, if it is being carried.
local function carrier_of(id: EntityId): EntityId?
	return carriers[id]
end

-- Every transport that is carrying anything, by id, and what it carries. Read only.
local function loaded(): { [EntityId]: { Entity } }
	return holds
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
	carriers[cargo.id] = nil
	carried_list = nil
	cargo.position = position
	cargo.velocity = Vector3.zero
	admit(cargo)
end

local function carried(): { Entity }
	local list = carried_list
	if list == nil then
		list = {}
		for _, hold in holds do
			for _, cargo in hold do
				table.insert(list, cargo)
			end
		end
		carried_list = list
	end
	return list
end

-- A transport that is gone takes whatever it was carrying with it.
local function drop_hold(transport_id: EntityId)
	local hold = holds[transport_id]
	if hold == nil then
		return
	end
	for _, cargo in hold do
		carriers[cargo.id] = nil
	end
	holds[transport_id] = nil
	carried_list = nil
end

-- Entities are flagged rather than deleted mid-tick so that iteration in progress stays valid;
-- `reap` clears them out at the end of the tick. Something that dies in a hold is taken out of it where it hangs,
-- so that `reap` finds it as it does anything else. Only `deaths` flags anything: whatever else takes something off
-- the map says why through it.
local function mark_dead(entity: Entity)
	entity.alive = false
	local transport_id = carriers[entity.id]
	if transport_id ~= nil then
		unstow(transport_id, entity, entity.position)
	end
end

-- Told the id of everything `reap` clears out, for whatever kept something about it to forget it.
local forgotten = signal.new() :: signal.Signal<EntityId>

-- Clears everything flagged dead out of the world, and has everything that kept something about it forget it. The step
-- does this at the end of every tick; replacing the map does it at once, so the world is empty before the new one is
-- built, paused or not.
local function reap()
	local removed = {}
	for id, entity in entities do
		if entity.alive == false then
			table.insert(removed, id)
			leave(id)
		end
	end
	-- something can be created and killed inside the same tick, so sweep the new arrivals too
	for id, entity in spawning do
		if entity.alive == false then
			table.insert(removed, id)
			spawning[id] = nil
		end
	end
	if #removed > 0 then
		membership += 1
	end
	for _, id in removed do
		forgotten.fire(id)
		-- a transport that is gone takes what it was carrying with it
		drop_hold(id)
	end
end

-- The world is kept whole: every entity, the ones in holds among them, every team, and the clock. Nothing is waiting
-- to join it between steps, and each index is filled again from what is back.
snapshot.keep("state", function()
	assert(stepping == false and next(spawning) == nil, "the world is only kept between steps")
	return {
		entities = entities,
		holds = holds,
		carriers = carriers,
		teams = team_records,
		next_entity_id = next_entity_id,
		membership = membership,
		elapsed = elapsed,
	}
end, function(saved)
	assert(stepping == false, "the world is only put back between steps")
	entities = saved.entities
	holds = saved.holds
	carriers = saved.carriers
	team_records = saved.teams
	next_entity_id = saved.next_entity_id
	membership = saved.membership
	elapsed = saved.elapsed
	spawning = {}
	carried_list = nil
	for _, index in indexes do
		table.clear(index.members)
		for id, entity in entities do
			if index.has(entity.def) then
				index.members[id] = entity
			end
		end
	end
end)

return table.freeze({
	RECLAIMABLE_BUILDPOWER_FRACTION = RECLAIMABLE_BUILDPOWER_FRACTION,
	create_team = create_team,
	on_created = created.subscribe,
	reset_team = reset_team,
	get_team = get_team,
	all_teams = all_teams,
	remove_team = remove_team,
	create_entity = create_entity,
	create_wreck = create_wreck,
	create_reclaimable = create_reclaimable,
	get = get,
	carrier_of = carrier_of,
	all = all,
	indexed = indexed,
	loaded = loaded,
	pending = pending,
	is_present = is_present,
	world_version = world_version,
	begin_step = begin_step,
	now = now,
	end_step = end_step,
	flush = flush,
	stow = stow,
	unstow = unstow,
	cargo_of = cargo_of,
	carried = carried,
	mark_dead = mark_dead,
	reap = reap,
	on_forget = forgotten.subscribe,
	max_health_for_progress = max_health_for_progress,
})
