--!strict
-- React hooks over what is kept outside React and told of as it changes: a store with a getter and a subscription (a
-- client module's state, a replicated field's accessors, shared/replicated.luau), an Instance's attribute, the size of
-- the viewport, or anything that only says that it changed. Each reads again when it is told and once more after
-- mounting, in case it changed between the first render and then, and renders again only when what it reads is not
-- the same value as before (so a store that hands out a new table each time renders each time it tells).

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local Workspace = game:GetService "Workspace"

local React = require(ReplicatedStorage.Packages.react)

-- Subscribes a listener, and returns the function that unsubscribes it.
export type Subscribe = (listener: () -> ()) -> () -> ()

-- What `get` says, following it every time `subscribe` tells of a change. `deps` are what `get` and `subscribe` read
-- that can change between renders; without them they are taken to be the same every render.
local function use_store<T>(get: () -> T, subscribe: Subscribe, deps: { any }?): T
	-- boxed, since React takes a state of nil for none given, and a function for an update to make
	local box, set_box = React.useState(function(): { value: T }
		return { value = get() }
	end)
	React.useEffect(function(): () -> ()
		local function refresh()
			local value = get()
			set_box(function(before: { value: T }): { value: T }
				return if before.value == value then before else { value = value }
			end)
		end
		refresh()
		return subscribe(refresh)
	end, deps or {})
	return box.value
end

-- How many times `subscribe` has told of a change, for a component that reads what changed for itself as it renders.
local function use_changes(subscribe: Subscribe, deps: { any }?): number
	local count, set_count = React.useState(0)
	React.useEffect(function(): () -> ()
		return subscribe(function()
			set_count(function(before: number): number
				return before + 1
			end)
		end)
	end, deps or {})
	return count
end

-- The attribute `name` of `instance`, when it holds a value of the type `kind` names ("string", "number", "boolean",
-- ...), and nil otherwise or without an instance.
local function use_attribute(instance: Instance?, name: string, kind: string): any
	return use_store(function(): any
		local value = if instance ~= nil then instance:GetAttribute(name) else nil
		return if typeof(value) == kind then value else nil
	end, function(listener: () -> ()): () -> ()
		if instance == nil then
			return function() end
		end
		local connection = instance:GetAttributeChangedSignal(name):Connect(listener)
		return function()
			connection:Disconnect()
		end
	end, { instance, name, kind } :: { any })
end

-- The size of the viewport, zero while there is no camera.
local function viewport_size(): Vector2
	local camera = Workspace.CurrentCamera
	return if camera ~= nil then camera.ViewportSize else Vector2.zero
end

local function viewport_resized(listener: () -> ()): () -> ()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return function() end
	end
	local connection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(listener)
	return function()
		connection:Disconnect()
	end
end

-- The size of the viewport, following it as the window changes size; it can settle a frame after mounting.
local function use_viewport_size(): Vector2
	return use_store(viewport_size, viewport_resized)
end

return table.freeze({
	use_store = use_store,
	use_changes = use_changes,
	use_attribute = use_attribute,
	use_viewport_size = use_viewport_size,
})
