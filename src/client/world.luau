-- The client's read-only view of the simulation. The server mirrors every entity into
-- Workspace.Entities as an anchored model carrying its state in attributes, so there is no
-- snapshot protocol to decode: reading an entity is reading a model.
--
-- Models are indexed by entity id as they arrive, because selection pruning and the HUD look
-- entities up many times a frame and scanning the folder each time does not scale.
--
-- A map can be strewn with thousands of reclaimables, rocks and trees that never move and almost never change, so
-- they are kept out of `all()`, which what runs every frame walks: they are only looked up by id (`get`), and the few
-- someone has started reclaiming are listed in `reclaimables_started()`, for the bars over them.
--
-- What is listed in either is told about as it changes, for what shows it to follow without looking again and again:
-- `subscribe_listed` as a model is listed, `subscribe_changed` with its id and the attribute whenever one of its
-- attributes changes, and `subscribe_removed` as any tracked model goes (reclaimables never started included), with
-- the id it had.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local signal = require(ReplicatedStorage.Shared.signal)
local entity_attrs = require(ReplicatedStorage.Shared.entity_attrs)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local switches = require(ReplicatedStorage.Shared.switches)
local teams = require(ReplicatedStorage.Shared.teams)
local seating = require(ReplicatedStorage.Shared.seating)

type EntityId = types.EntityId
type EntityDef = types.EntityDef

-- Whose side something is on, as `viewer` sees it (`relation`).
export type Relation = "own" | "ally" | "enemy" | "neutral"

local by_id: { [EntityId]: Model } = {}
local id_of_model: { [Model]: EntityId } = {}
-- every model but the reclaimables, and where in the list each one is, so one leaves in a swap rather than a rebuild
local models: { Model } = {}
local index_of: { [Model]: number } = {}
-- the reclaimables whose store has gone down from what they held, and where in the list each one is
local started: { Model } = {}
local started_index: { [Model]: number } = {}
-- the reclaimables not started yet, each waiting for its store to go down
local watching: { [Model]: RBXScriptConnection } = {}
-- what is listed in `models` or `started`, each told about as its attributes change
local attribute_connections: { [Model]: RBXScriptConnection } = {}
local folder: Folder? = nil

local listed = signal.new() :: signal.Signal<Model>
local changed = signal.new() :: signal.Signal<EntityId, string>
local removed = signal.new() :: signal.Signal<Model, EntityId>

local function container(): Folder
	if folder ~= nil then
		return folder
	end
	local found = Workspace:WaitForChild "Entities" :: Folder
	folder = found
	return found
end

local function add_to(list: { Model }, index: { [Model]: number }, model: Model, id: EntityId)
	if index[model] ~= nil then
		return
	end
	table.insert(list, model)
	index[model] = #list
	attribute_connections[model] = model.AttributeChanged:Connect(function(attribute: string)
		changed.fire(id, attribute)
	end)
	listed.fire(model)
end

local function remove_from(list: { Model }, index: { [Model]: number }, model: Model)
	local at = index[model]
	if at == nil then
		return
	end
	local last = list[#list]
	list[at] = last
	index[last] = at
	list[#list] = nil
	index[model] = nil
end

-- A reclaimable joins `started` once what is left in it drops below what it held, and stays until it is gone.
local function watch_reclaimable(model: Model, id: EntityId)
	local function check(): boolean
		local left = entity_attrs.number(model, "reclaim_left")
		local total = entity_attrs.number(model, "reclaim_total")
		if left ~= nil and total ~= nil and left < total then
			add_to(started, started_index, model, id)
			return true
		end
		return false
	end
	if check() then
		return
	end
	watching[model] = entity_attrs.changed(model, "reclaim_left"):Connect(function()
		if check() then
			local connection = watching[model]
			if connection ~= nil then
				connection:Disconnect()
				watching[model] = nil
			end
		end
	end)
end

local function add(model: Model, id: EntityId)
	by_id[id] = model
	id_of_model[model] = id
	if entity_attrs.kind(model) == "reclaimable" then
		watch_reclaimable(model, id)
	else
		add_to(models, index_of, model, id)
	end
end

local function track(child: Instance)
	if child:IsA "Model" == false then
		return
	end
	local model = child :: Model
	local id = entity_attrs.id(model)
	if id ~= nil then
		add(model, id)
		return
	end
	-- the model can replicate a frame before its attributes do
	local connection: RBXScriptConnection
	connection = entity_attrs.changed(model, "entity_id"):Connect(function()
		local late = entity_attrs.id(model)
		if late ~= nil then
			connection:Disconnect()
			add(model, late)
		end
	end)
end

local function untrack(child: Instance)
	if child:IsA "Model" == false then
		return
	end
	local model = child :: Model
	local id = id_of_model[model]
	if id == nil then
		return
	end
	id_of_model[model] = nil
	if by_id[id] == model then
		by_id[id] = nil
	end
	remove_from(models, index_of, model)
	remove_from(started, started_index, model)
	for _, connections in { watching, attribute_connections } do
		local connection = connections[model]
		if connection ~= nil then
			connection:Disconnect()
			connections[model] = nil
		end
	end
	removed.fire(model, id)
end

-- Every live entity model but the reclaimables. The returned table is reused, so callers must not hold onto it.
local function all(): { Model }
	return models
end

-- The reclaimables someone has started reclaiming. Reused like `all()`'s.
local function reclaimables_started(): { Model }
	return started
end

local function get(id: EntityId): Model?
	local model = by_id[id]
	if model == nil then
		return nil
	end
	if model.Parent == nil then
		untrack(model)
		return nil
	end
	return model
end

-- Walks up from whatever a raycast hit to the entity model that owns it.
local function from_instance(instance: Instance?): Model?
	local current = instance
	while current ~= nil do
		if current:IsA "Model" and entity_attrs.id(current) ~= nil then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- An entity's model keeps its id for as long as it is there, so a tracked one's is looked up rather than read off it
-- again: this is called for every model every frame.
local function id_of(model: Model): EntityId?
	return id_of_model[model] or entity_attrs.id(model)
end

-- The def `model` is of, or nil for one that names none. A wreck names the def of what it was.
local function def_of(model: Model): EntityDef?
	local def_name = entity_attrs.def_name(model)
	return if def_name ~= nil then unit_defs.defs[def_name] else nil
end

-- The def of the entity `id`, or nil when it is not there or names none.
local function def_of_id(id: EntityId): EntityDef?
	local model = get(id)
	return if model ~= nil then def_of(model) else nil
end

-- An entity model is placed by its pivot, whether or not it has a PrimaryPart, so that is where
-- the server put it and that is what the client reads back.
local function position_of(model: Model): Vector3
	return model:GetPivot().Position
end

-- Whether `model` is remains, a wreck or a reclaimable (`unit_defs.is_remains_kind`).
local function is_remains(model: Model): boolean
	local kind = entity_attrs.kind(model)
	return kind ~= nil and unit_defs.is_remains_kind(kind)
end

-- Whose side `model` is on as `viewer`, an entity model, sees it: the viewer's own team ("own"), a team allied with it
-- ("ally"), any other side ("enemy"), or nobody's ("neutral": rocks, trees and wrecks). An order is judged from what it
-- is given to, which in godmode can be on any team. `ally_group` is the same for every team in an alliance, itself
-- included, so comparing it tells an ally without the client knowing the alliance graph.
local function relation(model: Model, viewer: Model): Relation
	local team = entity_attrs.team(model)
	if team == nil or team == teams.NEUTRAL or is_remains(model) then
		return "neutral"
	end
	if team == entity_attrs.team(viewer) then
		return "own"
	end
	return if entity_attrs.number(model, "ally_group") == entity_attrs.number(viewer, "ally_group")
		then "ally"
		else "enemy"
end

-- Whether something on `viewer`'s side may attack `model`: an enemy's, or a wreck, which is nobody's but may be shot
-- apart all the same.
local function is_attackable(model: Model, viewer: Model): boolean
	return entity_attrs.kind(model) == "wreck" or relation(model, viewer) == "enemy"
end

-- Whether something on `viewer`'s side may guard `model`: its own side's or an ally's, never an enemy's or nobody's.
local function is_guardable(model: Model, viewer: Model): boolean
	local side = relation(model, viewer)
	return side == "own" or side == "ally"
end

-- Whether an entity is yours to select and command: on your team, or in godmode on any real team, and not a drone,
-- which its carrier looks after. Nobody's things are never anyone's.
local function is_mine(model: Model): boolean
	local team = entity_attrs.team(model)
	if team == nil or team == teams.NEUTRAL then
		return false
	end
	local def = def_of(model)
	if def ~= nil and unit_defs.is_drone(def) then
		return false
	end
	return switches.is_on "godmode" or team == seating.team_of(Players.LocalPlayer)
end

-- Whether the local player only watches: they are on no team, and command nothing.
local function spectating(): boolean
	return seating.is_spectator(Players.LocalPlayer)
end

-- Whether an entity can be selected: yours, or, for a spectator, anything on a real team, to see it and its team's
-- resources.
local function is_selectable(model: Model): boolean
	if is_mine(model) then
		return true
	end
	local team = entity_attrs.team(model)
	return spectating() and team ~= nil and team ~= teams.NEUTRAL
end

-- Your commanders on the field, lowest entity id first.
local function my_commanders(): { Model }
	local found: { Model } = {}
	for _, model in models do
		local def = def_of(model)
		if def ~= nil and unit_defs.is_commander(def) and is_mine(model) and id_of(model) ~= nil then
			table.insert(found, model)
		end
	end
	table.sort(found, function(a: Model, b: Model): boolean
		return (id_of(a) :: EntityId) < (id_of(b) :: EntityId)
	end)
	return found
end

local function init()
	local entities = container()
	for _, child in entities:GetChildren() do
		track(child)
	end
	entities.ChildAdded:Connect(track)
	entities.ChildRemoved:Connect(untrack)
end

return table.freeze({
	init = init,
	container = container,
	all = all,
	reclaimables_started = reclaimables_started,
	get = get,
	from_instance = from_instance,
	id_of = id_of,
	def_of = def_of,
	def_of_id = def_of_id,
	relation = relation,
	is_remains = is_remains,
	is_attackable = is_attackable,
	is_guardable = is_guardable,
	my_commanders = my_commanders,
	position_of = position_of,
	is_mine = is_mine,
	spectating = spectating,
	is_selectable = is_selectable,
	subscribe_listed = listed.subscribe,
	subscribe_changed = changed.subscribe,
	subscribe_removed = removed.subscribe,
})
