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

export type EntityView = {
	id: EntityId,
	def_name: string,
	display_name: string,
	subtitle: string?,
	kind: string,
	state: string,
	health: number,
	max_health: number,
	build_progress: number,
	buildpower_cost: number,
	order_count: number,
	queue: { string },
	-- how full a transport is, as "used / capacity" in slots; nil for anything that carries nothing
	cargo: string?,
	-- the missiles a launcher holds ready, as "ready / most"; nil for anything that stockpiles none
	missiles: string?,
	-- what it is making (positive) or spending (negative) each second, nil when it does neither right now
	metal_rate: number?,
	energy_rate: number?,
	-- what is holding it back: "energy", "metal" or "storage" (nowhere to put what it makes); nil when nothing is
	stalled: string?,
	-- a weapon that has a target and not the energy to fire
	need_energy: boolean,
	-- a plasma deflector's power and its most; nil for anything without one
	shield: string?,
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

local function cargo_of(model: Model): string?
	local used = model:GetAttribute "cargo_used"
	local capacity = model:GetAttribute "cargo_capacity"
	if typeof(used) ~= "number" or typeof(capacity) ~= "number" then
		return nil
	end
	return `{used} / {capacity}`
end

local function missiles_of(model: Model): string?
	local ready = model:GetAttribute "stockpile"
	local limit = model:GetAttribute "stockpile_limit"
	if typeof(ready) ~= "number" or typeof(limit) ~= "number" then
		return nil
	end
	return `{ready} / {limit}`
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

local function shield_of(model: Model): string?
	local held = model:GetAttribute "shield_power"
	local most = model:GetAttribute "shield_max"
	if typeof(held) ~= "number" or typeof(most) ~= "number" then
		return nil
	end
	return `{held} / {most}`
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
	return {
		id = id,
		def_name = def_name,
		display_name = def.display_name,
		subtitle = def.subtitle,
		kind = tostring(model:GetAttribute "kind"),
		state = tostring(model:GetAttribute "state"),
		health = (model:GetAttribute "health" :: number?) or 0,
		max_health = (model:GetAttribute "max_health" :: number?) or 1,
		build_progress = (model:GetAttribute "build_progress" :: number?) or 0,
		buildpower_cost = (model:GetAttribute "buildpower_cost" :: number?) or 1,
		order_count = (model:GetAttribute "order_count" :: number?) or 0,
		queue = split_queue(model:GetAttribute "queue"),
		cargo = cargo_of(model),
		missiles = missiles_of(model),
		metal_rate = number_attribute(model, "metal_rate"),
		energy_rate = number_attribute(model, "energy_rate"),
		stalled = string_attribute(model, "stalled"),
		need_energy = model:GetAttribute "need_energy" == true,
		shield = shield_of(model),
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
