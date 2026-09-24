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

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type EntityId = types.EntityId

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
local folder: Folder? = nil

local function container(): Folder
	if folder ~= nil then
		return folder
	end
	local found = Workspace:WaitForChild "Entities" :: Folder
	folder = found
	return found
end

local function add_to(list: { Model }, index: { [Model]: number }, model: Model)
	if index[model] ~= nil then
		return
	end
	table.insert(list, model)
	index[model] = #list
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
local function watch_reclaimable(model: Model)
	local function check(): boolean
		local left = model:GetAttribute "reclaim_left"
		local total = model:GetAttribute "reclaim_total"
		if typeof(left) == "number" and typeof(total) == "number" and left < total then
			add_to(started, started_index, model)
			return true
		end
		return false
	end
	if check() then
		return
	end
	watching[model] = model:GetAttributeChangedSignal("reclaim_left"):Connect(function()
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
	if model:GetAttribute "kind" == "reclaimable" then
		watch_reclaimable(model)
	else
		add_to(models, index_of, model)
	end
end

local function track(child: Instance)
	if child:IsA "Model" == false then
		return
	end
	local model = child :: Model
	local id = model:GetAttribute "entity_id"
	if typeof(id) == "number" then
		add(model, id)
		return
	end
	-- the model can replicate a frame before its attributes do
	local connection: RBXScriptConnection
	connection = model:GetAttributeChangedSignal("entity_id"):Connect(function()
		local late = model:GetAttribute "entity_id"
		if typeof(late) == "number" then
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
	if id ~= nil then
		id_of_model[model] = nil
		if by_id[id] == model then
			by_id[id] = nil
		end
	end
	remove_from(models, index_of, model)
	remove_from(started, started_index, model)
	local connection = watching[model]
	if connection ~= nil then
		connection:Disconnect()
		watching[model] = nil
	end
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
		if current:IsA "Model" and current:GetAttribute "entity_id" ~= nil then
			return current
		end
		current = current.Parent
	end
	return nil
end

local function id_of(model: Model): EntityId?
	local id = model:GetAttribute "entity_id"
	if typeof(id) ~= "number" then
		return nil
	end
	return id
end

-- An entity model is placed by its pivot, whether or not it has a PrimaryPart, so that is where
-- the server put it and that is what the client reads back.
local function position_of(model: Model): Vector3
	return model:GetPivot().Position
end

-- Whether an entity is yours to select and command: it is on your team, or the server is in
-- godmode and it is on any real team. The neutral team 0 is never anyone's.
local function is_mine(model: Model): boolean
	local team = model:GetAttribute "team"
	if typeof(team) ~= "number" then
		return false
	end
	-- a drone is not yours to pick or command: its carrier looks after it
	local def_name = model:GetAttribute "def_name"
	local def = if typeof(def_name) == "string" then unit_defs.defs[def_name] else nil
	if def ~= nil and def.drone == true then
		return false
	end
	if Workspace:GetAttribute "godmode" == true then
		return team ~= 0
	end
	return team == Players.LocalPlayer:GetAttribute "team"
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
	position_of = position_of,
	is_mine = is_mine,
})
