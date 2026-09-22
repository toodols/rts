-- The client's read-only view of the simulation. The server mirrors every entity into
-- Workspace.Entities as an anchored model carrying its state in attributes, so there is no
-- snapshot protocol to decode: reading an entity is reading a model.
--
-- Models are indexed by entity id as they arrive, because selection pruning and the HUD look
-- entities up many times a frame and scanning the folder each time does not scale.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type EntityId = types.EntityId

local by_id: { [EntityId]: Model } = {}
local models: { Model } = {}
local folder: Folder? = nil

local function container(): Folder
	if folder ~= nil then
		return folder
	end
	local found = Workspace:WaitForChild "Entities" :: Folder
	folder = found
	return found
end

local function rebuild_list()
	table.clear(models)
	for _, model in by_id do
		table.insert(models, model)
	end
end

local function track(child: Instance)
	if child:IsA "Model" == false then
		return
	end
	local model = child :: Model
	local id = model:GetAttribute "entity_id"
	if typeof(id) == "number" then
		by_id[id] = model
		rebuild_list()
		return
	end
	-- the model can replicate a frame before its attributes do
	local connection: RBXScriptConnection
	connection = model:GetAttributeChangedSignal("entity_id"):Connect(function()
		local late = model:GetAttribute "entity_id"
		if typeof(late) == "number" then
			by_id[late] = model
			rebuild_list()
			connection:Disconnect()
		end
	end)
end

local function untrack(child: Instance)
	for id, model in by_id do
		if model == child then
			by_id[id] = nil
			rebuild_list()
			return
		end
	end
end

-- Every live entity model. The returned table is reused, so callers must not hold onto it.
local function all(): { Model }
	return models
end

local function get(id: EntityId): Model?
	local model = by_id[id]
	if model == nil then
		return nil
	end
	if model.Parent == nil then
		by_id[id] = nil
		rebuild_list()
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
	get = get,
	from_instance = from_instance,
	id_of = id_of,
	position_of = position_of,
	is_mine = is_mine,
})
