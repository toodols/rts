-- Shared hooks for reading the selection and the live attributes of the models behind it.
--
-- Entity state lives on Workspace models rather than in a client-side store, so the HUD samples
-- those attributes on a timer instead of subscribing to a change stream. At a few entities on
-- screen that is far cheaper than wiring a listener to every attribute.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local React = require(ReplicatedStorage.Packages.react)

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local world = require(ReplicatedStorage.Client.world)
local selection = require(ReplicatedStorage.Client.selection)

type EntityId = types.EntityId

-- An amount out of a most, for what fills up: a shield's power, a launcher's missiles, a transport's slots.
export type Gauge = { value: number, most: number }

-- One source of what an entity makes or spends each second, as the server names it: "Generating", "Building Grunt".
export type FlowSource = { label: string, metal: number, energy: number }

export type EntityView = {
	id: EntityId,
	def_name: string,
	display_name: string,
	subtitle: string?,
	kind: string,
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
	-- how full a transport is, in slots; nil for anything that carries nothing
	cargo: Gauge?,
	-- the missiles a launcher holds ready; nil for anything that stockpiles none
	missiles: Gauge?,
	-- what it is making (positive) or spending (negative) each second, nil when it does neither right now
	metal_rate: number?,
	energy_rate: number?,
	-- what the two rates are made of, one entry a source; empty when it neither makes nor spends
	flow_sources: { FlowSource },
	-- what is holding it back: "energy", "metal" or "storage" (nowhere to put what it makes); nil when nothing is
	stalled: string?,
	-- a weapon that has a target and not the energy to fire
	need_energy: boolean,
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

local function split_queue(raw: unknown): { string }
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	local result = {}
	for name in string.gmatch(raw, "[^,]+") do
		table.insert(result, name)
	end
	return result
end

-- Two number attributes read as a gauge, or nil unless both are there.
local function gauge_of(model: Model, value_name: string, most_name: string): Gauge?
	local value = model:GetAttribute(value_name)
	local most = model:GetAttribute(most_name)
	if typeof(value) ~= "number" or typeof(most) ~= "number" then
		return nil
	end
	return { value = value, most = most }
end

local function number_attribute(model: Model, name: string): number?
	local value = model:GetAttribute(name)
	if typeof(value) ~= "number" then
		return nil
	end
	return value
end

local function string_attribute(model: Model, name: string): string?
	local value = model:GetAttribute(name)
	if typeof(value) ~= "string" then
		return nil
	end
	return value
end

-- The server's "label|metal|energy;..." (see server/flows.luau), taken apart.
local function flow_sources_of(model: Model): { FlowSource }
	local raw = model:GetAttribute "flow_sources"
	if typeof(raw) ~= "string" then
		return {}
	end
	local sources = {}
	for part in string.gmatch(raw, "[^;]+") do
		local label, metal, energy = string.match(part, "^(.*)|([^|]*)|([^|]*)$")
		if label ~= nil then
			table.insert(sources, { label = label, metal = tonumber(metal) or 0, energy = tonumber(energy) or 0 })
		end
	end
	return sources
end

local function view_of(id: EntityId): EntityView?
	local model = world.get(id)
	if model == nil then
		return nil
	end
	local def_name = model:GetAttribute "def_name"
	if typeof(def_name) ~= "string" then
		return nil
	end
	local def = unit_defs.defs[def_name]
	if def == nil then
		return nil
	end
	local team_color = model:GetAttribute "team_color"
	return {
		id = id,
		def_name = def_name,
		display_name = def.display_name,
		subtitle = def.subtitle,
		kind = tostring(model:GetAttribute "kind"),
		state = tostring(model:GetAttribute "state"),
		team = (model:GetAttribute "team" :: number?) or 0,
		team_name = string_attribute(model, "team_name"),
		team_color = if typeof(team_color) == "Color3" then team_color else nil,
		health = (model:GetAttribute "health" :: number?) or 0,
		max_health = (model:GetAttribute "max_health" :: number?) or 1,
		build_progress = (model:GetAttribute "build_progress" :: number?) or 0,
		buildpower_cost = (model:GetAttribute "buildpower_cost" :: number?) or 1,
		order_count = (model:GetAttribute "order_count" :: number?) or 0,
		queue = split_queue(model:GetAttribute "queue"),
		cargo = gauge_of(model, "cargo_used", "cargo_capacity"),
		missiles = gauge_of(model, "stockpile", "stockpile_limit"),
		metal_rate = number_attribute(model, "metal_rate"),
		energy_rate = number_attribute(model, "energy_rate"),
		flow_sources = flow_sources_of(model),
		stalled = string_attribute(model, "stalled"),
		need_energy = model:GetAttribute "need_energy" == true,
		shield = gauge_of(model, "shield_power", "shield_max"),
		kills = number_attribute(model, "kills") or 0,
		experience = number_attribute(model, "experience") or 0,
		metal_left = number_attribute(model, "metal_left"),
		energy_left = number_attribute(model, "energy_left"),
		reclaim_left = number_attribute(model, "reclaim_left"),
		reclaim_total = number_attribute(model, "reclaim_total"),
		resurrect_progress = number_attribute(model, "resurrect_progress"),
	}
end

local function use_selection(): { EntityId }
	local ids, set_ids = React.useState(selection.get)
	React.useEffect(function()
		return selection.subscribe(function(next_ids: { EntityId })
			set_ids(next_ids)
		end)
	end, {})
	return ids
end

-- Resamples the selected entities' attributes on a timer so bars and queues stay live.
local function use_views(ids: { EntityId }): { EntityView }
	local views, set_views = React.useState({} :: { EntityView })

	React.useEffect(function()
		local function sample()
			local next_views = {}
			for _, id in ids do
				local view = view_of(id)
				if view ~= nil then
					table.insert(next_views, view)
				end
			end
			set_views(next_views)
		end

		sample()
		local elapsed = 0
		local connection = RunService.Heartbeat:Connect(function(delta: number)
			elapsed += delta
			if elapsed < SAMPLE_INTERVAL then
				return
			end
			elapsed = 0
			sample()
		end)
		return function()
			connection:Disconnect()
		end
	end, { ids })

	return views
end

return table.freeze({
	use_selection = use_selection,
	use_views = use_views,
	view_of = view_of,
})
