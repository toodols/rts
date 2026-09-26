--!strict
-- The selection as what can be told what to do: each selected thing that takes orders, with its model and def. That
-- is the units, and the buildings that work, like a construction turret, or that make units, the labs, which keep
-- orders for the units they make. An unfinished one takes orders just like a finished one and carries them out once it
-- is built.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)

local world = require(ReplicatedStorage.Client.world)
local selection = require(ReplicatedStorage.Client.selection)
local order_modes = require(ReplicatedStorage.Client.order_modes)

type EntityId = types.EntityId
type EntityDef = types.EntityDef
type ModeInfo = order_modes.ModeInfo

export type Entry = { id: EntityId, model: Model, def: EntityDef }

-- The selected things that take orders, in selection order. `active_only` leaves out unfinished ones.
local function entries(active_only: boolean): { Entry }
	local result = {}
	for _, id in selection.get() do
		local model = world.get(id)
		local def = if model ~= nil then world.def_of(model) else nil
		if model == nil or def == nil then
			continue
		end
		if active_only and entity_attrs.state(model) ~= "active" then
			continue
		end
		if unit_defs.takes_orders(def) or unit_defs.is_factory(def) then
			table.insert(result, { id = id, model = model, def = def })
		end
	end
	return result
end

-- The selected things that can take part in the mode `info` describes.
local function for_mode(info: ModeInfo): { Entry }
	local result = {}
	for _, entry in entries(info.active_only) do
		if info.can(entry.def) then
			table.insert(result, entry)
		end
	end
	return result
end

-- The selected things that can be sent somewhere: what moves, and the labs, whose units go there once made.
local function movers(): { Entry }
	local result = {}
	for _, entry in entries(false) do
		if order_modes.can_go(entry.def) then
			table.insert(result, entry)
		end
	end
	return result
end

local function ids_of(list: { Entry }): { EntityId }
	local ids = table.create(#list)
	for index, entry in list do
		ids[index] = entry.id
	end
	return ids
end

-- The selected builders that can put up `def_name`, in selection order. The first is the one the server treats as
-- the builder when it snaps a building onto a metal spot (placement.resolve_center takes only one).
local function builders_of(def_name: string): { EntityId }
	local ids = {}
	for _, entry in entries(false) do
		if table.find(unit_defs.build_options(entry.def), def_name) ~= nil then
			table.insert(ids, entry.id)
		end
	end
	return ids
end

-- The selection's builder: the first selected thing that builds anything, a lab or a builder of buildings. The build
-- menu shows what it builds, and the build keys place what it can.
local function builder(): Entry?
	for _, entry in entries(false) do
		if #unit_defs.build_options(entry.def) > 0 then
			return entry
		end
	end
	return nil
end

-- The buildings the selection's builder can put up (`builder`): none for a lab, whose units are not put down.
local function buildable(): { string }
	local found = builder()
	if found == nil or unit_defs.does(found.def, "assist") == false then
		return {}
	end
	return unit_defs.build_options(found.def)
end

return table.freeze({
	entries = entries,
	for_mode = for_mode,
	movers = movers,
	ids_of = ids_of,
	builders_of = builders_of,
	builder = builder,
	buildable = buildable,
})
