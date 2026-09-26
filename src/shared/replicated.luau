--!strict
-- What the server tells every client of the game's state and of each player, other than what an entity's model carries
-- (shared/entity_attrs.luau) and what is sent on a remote. Each value is a field, declared once, by the module that
-- owns it, with a namespace, a name and a codec: the game's own on WorldState (a folder beside this module), and a
-- player's on their Player. Both are attributes, which reach a client whenever it joins and change a key at a time, so
-- what has to change together is one field.
--
-- - A field's key is `<namespace>_<name>`, and no two fields may share one.
-- - There is one encoding: a value of a type an attribute holds (a number, a string, a boolean, a Vector3, a Vector2, a
--   Color3) is stored as itself, and anything else (a list, a record) as JSON, read back through a check of its shape.
-- - Only the server sets a field, and nothing in the game reads the Workspace's attributes: those are the inputs a
--   developer sets by hand on the place in Studio (server/session_config.luau), never state.

local HttpService = game:GetService "HttpService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

-- How a field's value is stored as an attribute, and read back; nil for a value that is missing or not one.
export type Codec<T> = {
	encode: (value: T) -> any,
	decode: (stored: unknown) -> T?,
}

-- One of the game's values.
export type WorldField<T> = {
	key: string,
	get: () -> T?,
	-- the server's
	set: (value: T?) -> (),
	-- Calls `listener` whenever the value changes, until the returned function is called.
	changed: (listener: () -> ()) -> () -> (),
}

-- One of each player's values.
export type PlayerField<T> = {
	key: string,
	get: (player: Player) -> T?,
	-- the server's
	set: (player: Player, value: T?) -> (),
	changed: (player: Player, listener: () -> ()) -> () -> (),
}

local world_state: Instance = ReplicatedStorage.Shared.WorldState

-- Every key declared, so that no two fields share one.
local declared: { [string]: boolean } = {}

local function scalar<T>(kind: string): Codec<T>
	return table.freeze({
		encode = function(value: T): any
			return value
		end,
		decode = function(stored: unknown): T?
			return if typeof(stored) == kind then stored :: any else nil
		end,
	})
end

local NUMBER: Codec<number> = scalar "number"
local STRING: Codec<string> = scalar "string"
local BOOLEAN: Codec<boolean> = scalar "boolean"
local VECTOR3: Codec<Vector3> = scalar "Vector3"
local VECTOR2: Codec<Vector2> = scalar "Vector2"
local COLOR3: Codec<Color3> = scalar "Color3"

-- A value stored as JSON, and read back as whatever `check` makes of what was decoded, nil for what is not one.
local function json<T>(check: (decoded: any) -> T?): Codec<T>
	return table.freeze({
		encode = function(value: T): any
			return HttpService:JSONEncode(value)
		end,
		decode = function(stored: unknown): T?
			if typeof(stored) ~= "string" then
				return nil
			end
			local ok, decoded = pcall(HttpService.JSONDecode, HttpService, stored)
			return if ok then check(decoded) else nil
		end,
	})
end

-- A list of values of the type `item`, stored as JSON; anything in it that is not one is left out.
local function list_of<T>(item: string): Codec<{ T }>
	return json(function(decoded: any): { T }?
		if typeof(decoded) ~= "table" then
			return nil
		end
		local found: { T } = {}
		for _, each in decoded do
			if typeof(each) == item then
				table.insert(found, each)
			end
		end
		return found
	end)
end

local NUMBERS: Codec<{ number }> = list_of "number"
local STRINGS: Codec<{ string }> = list_of "string"

local function declare(namespace: string, name: string): string
	local key = `{namespace}_{name}`
	assert(declared[key] == nil, `the replicated field "{key}" is declared twice`)
	declared[key] = true
	return key
end

local function disconnecter(connection: RBXScriptConnection): () -> ()
	return function()
		connection:Disconnect()
	end
end

-- Encodes `value`, or nothing for nil.
local function encoded<T>(codec: Codec<T>, value: T?): any
	return if value ~= nil then codec.encode(value) else nil
end

-- The game's value `name` in `namespace`.
local function world<T>(namespace: string, name: string, codec: Codec<T>): WorldField<T>
	local key = declare(namespace, name)
	return table.freeze({
		key = key,
		get = function(): T?
			return codec.decode(world_state:GetAttribute(key))
		end,
		set = function(value: T?)
			local stored = encoded(codec, value)
			if world_state:GetAttribute(key) ~= stored then
				world_state:SetAttribute(key, stored)
			end
		end,
		changed = function(listener: () -> ()): () -> ()
			return disconnecter(world_state:GetAttributeChangedSignal(key):Connect(listener))
		end,
	})
end

-- Each player's value `name` in `namespace`.
local function player<T>(namespace: string, name: string, codec: Codec<T>): PlayerField<T>
	local key = declare(namespace, name)
	return table.freeze({
		key = key,
		get = function(owner: Player): T?
			return codec.decode(owner:GetAttribute(key))
		end,
		set = function(owner: Player, value: T?)
			local stored = encoded(codec, value)
			if owner:GetAttribute(key) ~= stored then
				owner:SetAttribute(key, stored)
			end
		end,
		changed = function(owner: Player, listener: () -> ()): () -> ()
			return disconnecter(owner:GetAttributeChangedSignal(key):Connect(listener))
		end,
	})
end

-- Calls `listener` whenever any of `fields` changes, until the returned function is called.
local function any_changed(fields: { WorldField<any> }, listener: () -> ()): () -> ()
	local stops: { () -> () } = {}
	for _, field in fields do
		table.insert(stops, field.changed(listener))
	end
	return function()
		for _, stop in stops do
			stop()
		end
	end
end

return table.freeze({
	NUMBER = NUMBER,
	STRING = STRING,
	BOOLEAN = BOOLEAN,
	VECTOR3 = VECTOR3,
	VECTOR2 = VECTOR2,
	COLOR3 = COLOR3,
	NUMBERS = NUMBERS,
	STRINGS = STRINGS,
	json = json,
	world = world,
	player = player,
	any_changed = any_changed,
})
