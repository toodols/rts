-- The little of the Roblox engine the server's simulation touches, for it to run outside Roblox (see README.md):
-- a DataModel of plain instances that hold properties, attributes and children, the services the server asks for,
-- signals, remote events that go nowhere, and a task scheduler driven by a clock of its own.
--
-- An instance here is a bag of properties: reading one that was never set gives nil, and anything that is set is kept.
-- Only what the server's code calls is here; a call to anything else fails loudly, naming it, so that a gap shows up
-- as an error and not as a quietly different game.

local serde = require "@lune/serde"

-- Signals ------------------------------------------------------------------------------------------------------------

local SignalMeta = {}
SignalMeta.__index = SignalMeta
SignalMeta.__type = "RBXScriptSignal"

local function new_signal(): any
	return setmetatable({ handlers = {} }, SignalMeta)
end

function SignalMeta:Connect(handler: (...any) -> ())
	local handlers = self.handlers
	local connection = { Connected = true }
	function connection.Disconnect()
		connection.Connected = false
		local at = table.find(handlers, handler)
		if at ~= nil then
			table.remove(handlers, at)
		end
	end
	table.insert(handlers, handler)
	return connection
end
SignalMeta.connect = SignalMeta.Connect

function SignalMeta:Once(handler: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		connection.Disconnect()
		handler(...)
	end)
	return connection
end

function SignalMeta:Fire(...)
	for _, handler in table.clone(self.handlers) do
		handler(...)
	end
end

function SignalMeta:Wait()
	error "a signal cannot be waited on headless"
end

-- Tasks --------------------------------------------------------------------------------------------------------------

-- The clock, in seconds of game, which task.wait and task.delay count by; whoever steps the game moves it on each step.
local now = 0
-- threads waiting, and when they may go on
local sleeping: { { thread: thread, at: number, started: number } } = {}
local deferred: { { thread: thread, args: { any } } } = {}

local function resume(thread: thread, ...)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		error(debug.traceback(thread, tostring(err)), 0)
	end
end

local task = {}

function task.spawn(callback: any, ...): thread
	local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
	resume(thread, ...)
	return thread
end

function task.defer(callback: any, ...): thread
	local thread = if type(callback) == "thread" then callback else coroutine.create(callback)
	table.insert(deferred, { thread = thread, args = table.pack(...) })
	return thread
end

function task.delay(seconds: number?, callback: any, ...): thread
	local args = table.pack(...)
	local thread = coroutine.create(function()
		task.wait(seconds)
		if type(callback) == "thread" then
			resume(callback, table.unpack(args, 1, args.n))
		else
			callback(table.unpack(args, 1, args.n))
		end
	end)
	resume(thread)
	return thread
end

-- In a thread of its own it waits for the clock; on the main thread, which nothing could resume, it returns
-- at once.
function task.wait(seconds: number?): number
	local thread = coroutine.running()
	if not coroutine.isyieldable() then
		return 0
	end
	table.insert(sleeping, { thread = thread, at = now + (seconds or 0), started = now })
	return coroutine.yield()
end

function task.cancel(thread: thread)
	for index = #sleeping, 1, -1 do
		if sleeping[index].thread == thread then
			table.remove(sleeping, index)
		end
	end
	pcall(coroutine.close, thread)
end

task.synchronize = function() end
task.desynchronize = function() end

-- Moves the clock to `time` and lets every thread whose wait is up, and everything deferred, go on.
local function run_tasks(time: number)
	now = time
	while #deferred > 0 do
		local batch = deferred
		deferred = {}
		for _, entry in batch do
			if coroutine.status(entry.thread) == "suspended" then
				resume(entry.thread, table.unpack(entry.args, 1, entry.args.n))
			end
		end
	end
	local due = {}
	for index = #sleeping, 1, -1 do
		local entry = sleeping[index]
		if entry.at <= now then
			table.remove(sleeping, index)
			table.insert(due, 1, entry)
		end
	end
	for _, entry in due do
		if coroutine.status(entry.thread) == "suspended" then
			resume(entry.thread, now - entry.started)
		end
	end
end

-- Instances ----------------------------------------------------------------------------------------------------------

local InstanceMeta = {}
local instance_methods = {}
-- what each class counts as, for IsA
local CLASS_PARENTS: { [string]: string } = {
	Part = "BasePart",
	MeshPart = "BasePart",
	WedgePart = "BasePart",
	BasePart = "PVInstance",
	Model = "PVInstance",
	PVInstance = "Instance",
	ModuleScript = "LuaSourceContainer",
	Script = "BaseScript",
	LocalScript = "BaseScript",
	BaseScript = "LuaSourceContainer",
	LuaSourceContainer = "Instance",
	RemoteEvent = "BaseRemoteEvent",
	UnreliableRemoteEvent = "BaseRemoteEvent",
	BaseRemoteEvent = "Instance",
	Folder = "Instance",
}

local function raw(self): any
	return rawget(self, "_")
end

local function new_instance(class_name: string, name: string?): any
	local data = {
		class = class_name,
		props = { Name = name or class_name },
		children = {},
		parent = nil,
		attributes = {},
		attribute_signals = {},
		property_signals = {},
		child_added = new_signal(),
		child_removed = new_signal(),
		destroying = new_signal(),
	}
	local self = setmetatable({ _ = data }, InstanceMeta)
	if class_name == "RemoteEvent" or class_name == "UnreliableRemoteEvent" then
		data.props.OnServerEvent = new_signal()
		data.props.OnClientEvent = new_signal()
	elseif class_name == "BindableEvent" then
		data.props.Event = new_signal()
	elseif class_name == "RemoteFunction" or class_name == "BindableFunction" then
		data.props.OnServerInvoke = nil
	end
	return self
end

InstanceMeta.__type = "Instance"
InstanceMeta.__tostring = function(self)
	return raw(self).props.Name
end
InstanceMeta.__index = function(self, key)
	local data = raw(self)
	if key == "Parent" then
		return data.parent
	elseif key == "ClassName" then
		return data.class
	end
	local value = data.props[key]
	if value ~= nil then
		return value
	end
	local method = instance_methods[key]
	if method ~= nil then
		return method
	end
	-- a child by name, as Roblox lets `parent.child` read
	for _, child in data.children do
		if raw(child).props.Name == key then
			return child
		end
	end
	return nil
end
InstanceMeta.__newindex = function(self, key, value)
	local data = raw(self)
	if key == "Parent" then
		local old = data.parent
		if old == value then
			return
		end
		if old ~= nil then
			local siblings = raw(old).children
			local at = table.find(siblings, self)
			if at ~= nil then
				table.remove(siblings, at)
			end
			raw(old).child_removed:Fire(self)
		end
		data.parent = value
		if value ~= nil then
			table.insert(raw(value).children, self)
			raw(value).child_added:Fire(self)
		end
		return
	end
	data.props[key] = value
	local signal = data.property_signals[key]
	if signal ~= nil then
		signal:Fire()
	end
end

function instance_methods.GetChildren(self)
	return table.clone(raw(self).children)
end
function instance_methods.GetDescendants(self)
	local found = {}
	local function walk(instance)
		for _, child in raw(instance).children do
			table.insert(found, child)
			walk(child)
		end
	end
	walk(self)
	return found
end
function instance_methods.FindFirstChild(self, name: string, recursive: boolean?)
	for _, child in raw(self).children do
		if raw(child).props.Name == name then
			return child
		end
	end
	if recursive then
		for _, child in raw(self).children do
			local found = instance_methods.FindFirstChild(child, name, true)
			if found ~= nil then
				return found
			end
		end
	end
	return nil
end
function instance_methods.WaitForChild(self, name: string)
	local found = instance_methods.FindFirstChild(self, name)
	if found == nil then
		error(`{instance_methods.GetFullName(self)} has no child "{name}" to wait for headless`)
	end
	return found
end
function instance_methods.IsA(self, class_name: string): boolean
	local class = raw(self).class
	while class ~= nil do
		if class == class_name then
			return true
		end
		class = CLASS_PARENTS[class]
	end
	return class_name == "Instance"
end
function instance_methods.FindFirstChildOfClass(self, class_name: string)
	for _, child in raw(self).children do
		if raw(child).class == class_name then
			return child
		end
	end
	return nil
end
function instance_methods.FindFirstChildWhichIsA(self, class_name: string)
	for _, child in raw(self).children do
		if instance_methods.IsA(child, class_name) then
			return child
		end
	end
	return nil
end
function instance_methods.FindFirstAncestor(self, name: string)
	local at = raw(self).parent
	while at ~= nil do
		if raw(at).props.Name == name then
			return at
		end
		at = raw(at).parent
	end
	return nil
end
function instance_methods.GetFullName(self): string
	local names = {}
	local at = self
	while at ~= nil do
		table.insert(names, 1, raw(at).props.Name)
		at = raw(at).parent
	end
	return table.concat(names, ".")
end
function instance_methods.GetAttribute(self, name: string)
	return raw(self).attributes[name]
end
function instance_methods.GetAttributes(self)
	return table.clone(raw(self).attributes)
end
function instance_methods.SetAttribute(self, name: string, value: any)
	local data = raw(self)
	if data.attributes[name] == value then
		return
	end
	data.attributes[name] = value
	local signal = data.attribute_signals[name]
	if signal ~= nil then
		signal:Fire()
	end
end
function instance_methods.GetAttributeChangedSignal(self, name: string)
	local data = raw(self)
	local signal = data.attribute_signals[name]
	if signal == nil then
		signal = new_signal()
		data.attribute_signals[name] = signal
	end
	return signal
end
function instance_methods.GetPropertyChangedSignal(self, name: string)
	local data = raw(self)
	local signal = data.property_signals[name]
	if signal == nil then
		signal = new_signal()
		data.property_signals[name] = signal
	end
	return signal
end
function instance_methods.Destroy(self)
	raw(self).destroying:Fire()
	for _, child in table.clone(raw(self).children) do
		instance_methods.Destroy(child)
	end
	self.Parent = nil
end
function instance_methods.ClearAllChildren(self)
	for _, child in table.clone(raw(self).children) do
		instance_methods.Destroy(child)
	end
end
function instance_methods.Clone(self)
	local data = raw(self)
	local copy = new_instance(data.class, data.props.Name)
	for key, value in data.props do
		raw(copy).props[key] = value
	end
	for key, value in data.attributes do
		raw(copy).attributes[key] = value
	end
	for _, child in data.children do
		instance_methods.Clone(child).Parent = copy
	end
	return copy
end
-- remote events go nowhere: nobody is connected
function instance_methods.FireClient() end
function instance_methods.FireAllClients() end
function instance_methods.FireServer() end
function instance_methods.Fire(self, ...)
	local event = raw(self).props.Event
	if event ~= nil then
		event:Fire(...)
	end
end
function instance_methods.PivotTo(self, frame)
	raw(self).props.WorldPivot = frame
end
function instance_methods.GetPivot(self)
	return raw(self).props.WorldPivot
end
instance_methods.ChildAdded = nil

-- the signals every instance has, read as properties
local SIGNAL_PROPERTIES = { ChildAdded = "child_added", ChildRemoved = "child_removed", Destroying = "destroying" }
local plain_index = InstanceMeta.__index
InstanceMeta.__index = function(self, key)
	local signal = SIGNAL_PROPERTIES[key]
	if signal ~= nil then
		return raw(self)[signal]
	end
	return plain_index(self, key)
end

-- The DataModel ------------------------------------------------------------------------------------------------------

local game = new_instance("DataModel", "Game")
local services: { [string]: any } = {}

local function service(name: string): any
	local found = services[name]
	if found == nil then
		found = new_instance(name, name)
		found.Parent = game
		services[name] = found
	end
	return found
end

raw(game).props.PrivateServerId = ""
raw(game).props.PrivateServerOwnerId = 0
raw(game).props.PlaceId = 0
raw(game).props.GameId = 0
raw(game).props.JobId = "arena"
raw(game).props.CreatorId = 0
-- the process ends without closing the game
function instance_methods.BindToClose() end
function instance_methods.GetService(self, name: string)
	if self ~= game then
		error "GetService is only for the DataModel"
	end
	return service(name)
end
instance_methods.FindService = instance_methods.GetService

-- Workspace
local workspace = service "Workspace"
raw(workspace).props.Terrain = new_instance("Terrain", "Terrain")
raw(workspace).props.Terrain.Parent = workspace
function instance_methods.GetServerTimeNow(): number
	return now
end

-- Players: nobody ever joins a game played headless
local players = service "Players"
raw(players).props.PlayerAdded = new_signal()
raw(players).props.PlayerRemoving = new_signal()
raw(players).props.CharacterAutoLoads = false
function instance_methods.GetPlayers(): { any }
	return {}
end
function instance_methods.GetPlayerByUserId(): any
	return nil
end

-- RunService: a Studio run of the server, which nobody plays
local run_service = service "RunService"
raw(run_service).props.Heartbeat = new_signal()
raw(run_service).props.Stepped = new_signal()
raw(run_service).props.PostSimulation = new_signal()
raw(run_service).props.PreSimulation = new_signal()
function instance_methods.IsStudio(): boolean
	return true
end
function instance_methods.IsServer(): boolean
	return true
end
function instance_methods.IsClient(): boolean
	return false
end
function instance_methods.IsRunMode(): boolean
	return true
end
function instance_methods.IsRunning(): boolean
	return true
end

-- TeleportService: nobody is ever sent anywhere
raw(service "TeleportService").props.TeleportInitFailed = new_signal()

-- HttpService
local http_service = service "HttpService"
function instance_methods.JSONEncode(_, value: any): string
	return serde.encode("json", value)
end
function instance_methods.JSONDecode(_, text: string): any
	return serde.decode("json", text)
end
local guid_count = 0
function instance_methods.GenerateGUID(): string
	guid_count += 1
	return string.format("{00000000-0000-0000-0000-%012d}", guid_count)
end
local _ = http_service

-- Stores that never have anything in them: reading one fails, as it does in Studio without API access, and every
-- caller wraps them in pcall.
local function no_store()
	error "there are no data stores headless"
end
instance_methods.GetDataStore = no_store
instance_methods.GetOrderedDataStore = no_store
instance_methods.GetHashMap = no_store
instance_methods.GetSortedMap = no_store
instance_methods.GetQueue = no_store

local function Instance_new(class_name: string, parent: any?): any
	local instance = new_instance(class_name)
	if parent ~= nil then
		instance.Parent = parent
	end
	return instance
end

return {
	game = game,
	workspace = workspace,
	Instance = table.freeze({ new = Instance_new }),
	new_instance = new_instance,
	task = table.freeze(task),
	run_tasks = run_tasks,
	new_signal = new_signal,
	-- sets a property without going through the usual assignment, for the loader
	raw_props = function(instance: any): { [string]: any }
		return raw(instance).props
	end,
}
