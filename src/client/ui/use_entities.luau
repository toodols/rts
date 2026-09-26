-- Reading an entity's model for the HUD (`view_of`, the one reader of what its attributes say that the panels and the
-- bars over the field both draw from), and hooks for reading the selection and the live views of the models behind it.
--
-- Entity state lives on Workspace models rather than in a client-side store. A view of them is taken again when the
-- world says one of their attributes changed (world's `subscribe_changed`), at most every SAMPLE_INTERVAL, and only
-- handed on when it differs from the last, so a panel renders again only when what it shows has changed.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

local types = require(ReplicatedStorage.Shared.types)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local seating = require(ReplicatedStorage.Shared.seating)

local world = require(ReplicatedStorage.Client.world)
local selection = require(ReplicatedStorage.Client.selection)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

type EntityId = types.EntityId

-- An amount out of a most, for what fills up: a shield's power, a launcher's missiles, a transport's slots.
export type Gauge = { value: number, most: number }

export type EntityView = {
	id: EntityId,
	def_name: string,
	display_name: string,
	subtitle: string?,
	kind: types.EntityKind,
	state: string,
	-- who it belongs to: the numeric team, its name if it has one, and the colour to show it in.
	-- Team 0 is neutral scenery, a wreck say, and has neither a name nor a set colour.
	team: number,
	team_name: string?,
	team_color: Color3?,
	health: number,
	max_health: number,
	build_progress: number,
	buildpower_cost: number,
	order_count: number,
	queue: { string },
	-- how full a transport is, in things carried; nil for anything that carries nothing
	cargo: Gauge?,
	-- the missiles a launcher holds ready; nil for anything that stockpiles none
	missiles: Gauge?,
	-- what it is making (positive) or spending (negative) each second, nil when it does neither right now
	metal_rate: number?,
	energy_rate: number?,
	-- what the two rates are made of, one entry a source; empty when it neither makes nor spends
	flow_sources: { entity_attrs.FlowSource },
	-- what is holding it back: "energy", "metal" or "storage" (nowhere to put what it makes); nil when nothing is
	stalled: string?,
	-- a weapon that has a target and not the energy to fire, and a lab whose next unit has nowhere to come out
	need_energy: boolean,
	exit_blocked: boolean,
	-- a blueprint losing progress for nobody building it
	decaying: boolean,
	-- whole seconds until it destroys itself, while it is counting down, and whether it is yours
	self_destruct: number?,
	mine: boolean,
	-- how far a slow weapon is through its reload, and a launcher through making its next missile, from 0 to 1
	reload_progress: number?,
	stockpile_progress: number?,
	-- its EMP in whole percent of what stuns it, and while it is stunned, whole seconds left
	emp: number?,
	stun: number?,
	-- a plasma deflector's power; nil for anything without one
	shield: Gauge?,
	-- enemies it has killed, and the experience it has earned in battle
	kills: number,
	experience: number,
	-- for a wreck or a reclaimable: the metal and energy still in it, and the buildpower still to be put into
	-- reclaiming it out of all it takes; nil for anything else
	metal_left: number?,
	energy_left: number?,
	reclaim_left: number?,
	reclaim_total: number?,
	-- for a wreck: how far raising it again has got, as a fraction
	resurrect_progress: number?,
}

local SAMPLE_INTERVAL = 0.1

-- Two number attributes read as a gauge, or nil unless both are there.
local function gauge_of(model: Model, value_name: entity_attrs.NumberName, most_name: entity_attrs.NumberName): Gauge?
	local value = entity_attrs.number(model, value_name)
	local most = entity_attrs.number(model, most_name)
	if value == nil or most == nil then
		return nil
	end
	return { value = value, most = most }
end

-- What the model of `id` says of it, or nil when it is not there.
local function view_of(id: EntityId): EntityView?
	local model = world.get(id)
	if model == nil then
		return nil
	end
	local def = world.def_of(model)
	local kind: types.EntityKind? = entity_attrs.kind(model)
	if def == nil or kind == nil then
		return nil
	end
	return {
		id = id,
		def_name = def.name,
		display_name = def.display_name,
		subtitle = def.subtitle,
		kind = kind,
		state = tostring(entity_attrs.state(model)),
		team = entity_attrs.team(model) or 0,
		team_name = entity_attrs.text(model, "team_name"),
		team_color = entity_attrs.color(model, "team_color"),
		health = entity_attrs.number(model, "health") or 0,
		max_health = entity_attrs.number(model, "max_health") or 1,
		build_progress = entity_attrs.number(model, "build_progress") or 0,
		buildpower_cost = entity_attrs.number(model, "buildpower_cost") or 1,
		order_count = entity_attrs.number(model, "order_count") or 0,
		queue = entity_attrs.queue(model),
		cargo = gauge_of(model, "cargo_used", "cargo_capacity"),
		missiles = gauge_of(model, "stockpile", "stockpile_limit"),
		metal_rate = entity_attrs.number(model, "metal_rate"),
		energy_rate = entity_attrs.number(model, "energy_rate"),
		flow_sources = entity_attrs.flow_sources(model),
		stalled = entity_attrs.text(model, "stalled"),
		need_energy = entity_attrs.flag(model, "need_energy") == true,
		exit_blocked = entity_attrs.flag(model, "exit_blocked") == true,
		decaying = entity_attrs.flag(model, "decaying") == true,
		self_destruct = entity_attrs.number(model, "self_destruct"),
		mine = world.is_mine(model),
		reload_progress = entity_attrs.number(model, "reload_progress"),
		stockpile_progress = entity_attrs.number(model, "stockpile_progress"),
		emp = entity_attrs.number(model, "emp"),
		stun = entity_attrs.number(model, "stun"),
		shield = gauge_of(model, "shield_power", "shield_max"),
		kills = entity_attrs.number(model, "kills") or 0,
		experience = entity_attrs.number(model, "experience") or 0,
		metal_left = entity_attrs.number(model, "metal_left"),
		energy_left = entity_attrs.number(model, "energy_left"),
		reclaim_left = entity_attrs.number(model, "reclaim_left"),
		reclaim_total = entity_attrs.number(model, "reclaim_total"),
		resurrect_progress = entity_attrs.number(model, "resurrect_progress"),
	}
end

local function use_selection(): { EntityId }
	return use_store.use_store(selection.get, selection.subscribe)
end

-- Whether two views (or any two values made of plain data) say the same.
local function same(a: any, b: any): boolean
	if typeof(a) ~= "table" or typeof(b) ~= "table" then
		return a == b
	end
	for key, value in a do
		if same(value, b[key]) == false then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function views_of(ids: { EntityId }): { EntityView }
	local views = {}
	for _, id in ids do
		local view = view_of(id)
		if view ~= nil then
			table.insert(views, view)
		end
	end
	return views
end

-- The views of `ids`, kept up with their attributes.
local function use_views(ids: { EntityId }): { EntityView }
	local views, set_views = React.useState(function(): { EntityView }
		return views_of(ids)
	end)

	React.useEffect(function(): () -> ()
		local watched: { [EntityId]: boolean } = {}
		for _, id in ids do
			watched[id] = true
		end
		local shown = views
		local function sample()
			local next_views = views_of(ids)
			if same(next_views, shown) == false then
				shown = next_views
				set_views(next_views)
			end
		end
		sample()

		local stale = false
		local since = 0
		local stop_changed = world.subscribe_changed(function(id: EntityId, _attribute: string)
			if watched[id] == true then
				stale = true
			end
		end)
		local stop_removed = world.subscribe_removed(function(_model: Model, id: EntityId)
			if watched[id] == true then
				stale = true
			end
		end)
		local connection = RunService.Heartbeat:Connect(function(delta: number)
			since += delta
			if stale and since >= SAMPLE_INTERVAL then
				stale = false
				since = 0
				sample()
			end
		end)
		return function()
			stop_changed()
			stop_removed()
			connection:Disconnect()
		end
	end, { ids })

	return views
end

-- Whether the local player only watches (world.spectating), kept up to date as that changes.
local function use_spectating(): boolean
	return use_store.use_store(world.spectating, function(listener: () -> ()): () -> ()
		return seating.spectator_changed(Players.LocalPlayer, listener)
	end)
end

return table.freeze({
	view_of = view_of,
	use_selection = use_selection,
	use_spectating = use_spectating,
	use_views = use_views,
})
