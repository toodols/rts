-- The HUD's own 3D pictures: keys, a mouse, a cursor, a tick and a cross, for the tutorial's cards. Their art is
-- made by tools/model_pipeline like any def's, one module each in Shared.ui_art in the same format as Shared.art's,
-- but belongs to no def: each is built here once, the first time it is asked for, and every picture of it is a copy.
-- Each MeshPart is named after its art group (a key, a mouse button), so a picture can light the part it means.
--
-- A picture whose module is not there (yet) is "missing", and whoever draws it shows something plainer instead.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local shared_art = require(ReplicatedStorage.Shared.art)

local art = require(ReplicatedStorage.Client.art)

type Art = shared_art.Art

export type Status = "ready" | "building" | "missing" | "failed"

local templates: { [string]: Model } = {}
-- the meshes each template was built from, kept for as long as the template is
local kept: { [string]: { EditableMesh } } = {}
local building: { [string]: boolean } = {}
local failed: { [string]: boolean } = {}
local waiting_for: { [string]: { () -> () } } = {}

local function module_of(name: string): ModuleScript?
	local folder = ReplicatedStorage.Shared:FindFirstChild "ui_art"
	local module = if folder ~= nil then folder:FindFirstChild(name) else nil
	if module == nil or module:IsA "ModuleScript" == false then
		return nil
	end
	return module :: ModuleScript
end

local function status(name: string): Status
	if templates[name] ~= nil then
		return "ready"
	elseif building[name] == true then
		return "building"
	elseif failed[name] == true then
		return "failed"
	elseif module_of(name) == nil then
		return "missing"
	end
	-- there to be built, and not started yet
	return "building"
end

local function finish(name: string)
	building[name] = nil
	local callbacks = waiting_for[name]
	waiting_for[name] = nil
	if callbacks ~= nil then
		for _, callback in callbacks do
			task.spawn(callback)
		end
	end
end

-- Starts building `name`, once. It yields, so it runs in a thread of its own.
local function build(name: string)
	if templates[name] ~= nil or building[name] == true or failed[name] == true then
		return
	end
	local module = module_of(name)
	if module == nil then
		return
	end
	building[name] = true
	task.spawn(function()
		local ok, model, editables = pcall(function(): (Model, { EditableMesh })
			local data = (require :: any)(module) :: Art
			return art.build_model(data, name)
		end)
		if ok then
			templates[name] = model
			kept[name] = editables
		else
			failed[name] = true
			warn(`could not build the HUD art {name}: {model}`)
		end
		finish(name)
	end)
end

-- A copy of `name`'s picture at rest, its origin at the origin, or nil while there is none: see `status` for why.
local function copy(name: string): Model?
	local template = templates[name]
	if template == nil then
		build(name)
		return nil
	end
	return template:Clone()
end

-- Calls `callback` once `name` has been built or has failed to be, starting it building if it had not yet. Only
-- for one whose status is "building". Returns a function that cancels the call.
local function when_built(name: string, callback: () -> ()): () -> ()
	local callbacks = waiting_for[name]
	if callbacks == nil then
		callbacks = {}
		waiting_for[name] = callbacks
	end
	table.insert(callbacks, callback)
	build(name)
	return function()
		local index = table.find(callbacks, callback)
		if index ~= nil then
			table.remove(callbacks, index)
		end
	end
end

-- Builds every picture there is and returns once they are all built or failed, or `timeout` seconds have gone by. A
-- game that shows them (the tutorial) calls it before anything else builds meshes, since the client's EditableMesh
-- memory is shared, and what is built last is what runs out of it.
local function preload(timeout: number)
	local folder = ReplicatedStorage.Shared:FindFirstChild "ui_art"
	if folder == nil then
		return
	end
	for _, module in folder:GetChildren() do
		if module:IsA "ModuleScript" then
			build(module.Name)
		end
	end
	local deadline = os.clock() + timeout
	while next(building) ~= nil and os.clock() < deadline do
		task.wait()
	end
end

return table.freeze({
	preload = preload,
	status = status,
	copy = copy,
	when_built = when_built,
})
