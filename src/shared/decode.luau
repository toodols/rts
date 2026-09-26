--!strict
-- Reading what a client sends. Nothing a client sends is trusted: a number may be NaN or infinite, a vector may hold
-- either, a list may be as long as it likes and a table may hold anything. Each remote says what it takes as decoders
-- built from these, and what arrives is read through them before anything uses it (server_shared/remotes.luau
-- for the game's remotes, lobby/shared/protocol.luau for the lobby's requests), so that no handler looks at raw input.
--
-- A decoder answers whether the value is one it takes, and if it is, the value as it is to be used.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local heightmap = require(ReplicatedStorage.Shared.heightmap)

export type Decoder<T> = (value: unknown) -> (boolean, T)

local function refuse(): (boolean, any)
	return false, nil
end

-- A real number: neither NaN nor infinite.
local function number(value: unknown): (boolean, number)
	if typeof(value) ~= "number" or value ~= value or math.abs(value) == math.huge then
		return refuse()
	end
	return true, value
end

-- A real number, rounded down to a whole one.
local function whole(value: unknown): (boolean, number)
	local ok, real = number(value)
	if ok == false then
		return refuse()
	end
	return true, math.floor(real)
end

-- A real number that is whole already, as a side or an index is: never a fraction.
local function integer(value: unknown): (boolean, number)
	local ok, real = number(value)
	if ok == false or real ~= math.floor(real) then
		return refuse()
	end
	return true, real
end

-- A Vector3 every part of which is a real number.
local function vector(value: unknown): (boolean, Vector3)
	if typeof(value) ~= "Vector3" then
		return refuse()
	end
	if number(value.X) == false or number(value.Y) == false or number(value.Z) == false then
		return refuse()
	end
	return true, value
end

-- A vector over the map: real, and inside its bounds, whatever its height.
local function on_map(value: unknown): (boolean, Vector3)
	local ok, point = vector(value)
	if ok == false or heightmap.in_bounds(point.X, point.Z) == false then
		return refuse()
	end
	return true, point
end

local function text(value: unknown): (boolean, string)
	if typeof(value) ~= "string" then
		return refuse()
	end
	return true, value
end

local function boolean(value: unknown): (boolean, boolean)
	if typeof(value) ~= "boolean" then
		return refuse()
	end
	return true, value
end

-- Whether it is true, anything else being false: a flag a client leaves out when it is off.
local function flag(value: unknown): (boolean, boolean)
	return true, value == true
end

-- Nothing: an argument a remote takes none of, whatever is sent in its place.
local function none(_value: unknown): (boolean, nil)
	return true, nil
end

-- One of `words`, exactly.
local function one_of<T>(words: { T }): Decoder<T>
	return function(value: unknown): (boolean, T)
		if typeof(value) ~= "string" or table.find(words, value :: any) == nil then
			return refuse()
		end
		return true, value :: any
	end
end

-- One of the keys of `map`.
local function key_of<V>(map: { [string]: V }): Decoder<string>
	return function(value: unknown): (boolean, string)
		if typeof(value) ~= "string" or map[value] == nil then
			return refuse()
		end
		return true, value
	end
end

-- Nil, or what `item` takes.
local function optional<T>(item: Decoder<T>): Decoder<T?>
	return function(value: unknown): (boolean, T?)
		if value == nil then
			return true, nil
		end
		return item(value)
	end
end

-- A list of at most `most` of what `item` takes, and nothing else.
local function list<T>(item: Decoder<T>, most: number): Decoder<{ T }>
	return function(value: unknown): (boolean, { T })
		if typeof(value) ~= "table" then
			return refuse()
		end
		local raw = value :: { unknown }
		if #raw > most then
			return refuse()
		end
		local read: { T } = table.create(#raw)
		for index = 1, #raw do
			local ok, each = item(raw[index])
			if ok == false then
				return refuse()
			end
			read[index] = each
		end
		return true, read
	end
end

-- The first `most` of a list of what `item` takes, the rest being left unread: for a list a client may make as long as
-- it likes, of which only so many are acted on.
local function first<T>(item: Decoder<T>, most: number): Decoder<{ T }>
	local whole_list = list(item, most)
	return function(value: unknown): (boolean, { T })
		if typeof(value) ~= "table" then
			return refuse()
		end
		local raw = value :: { unknown }
		return whole_list(if #raw > most then table.move(raw, 1, most, 1, {}) else raw)
	end
end

-- A table with each of `fields` as its decoder takes it; whatever else it holds is left out.
local function record(fields: { [string]: Decoder<any> }): Decoder<{ [string]: any }>
	return function(value: unknown): (boolean, { [string]: any })
		if typeof(value) ~= "table" then
			return refuse()
		end
		local raw = value :: { [unknown]: unknown }
		local read: { [string]: any } = {}
		for key, field in fields do
			local ok, each = field(raw[key])
			if ok == false then
				return refuse()
			end
			read[key] = each
		end
		return true, read
	end
end

return table.freeze({
	number = number,
	whole = whole,
	integer = integer,
	vector = vector,
	on_map = on_map,
	text = text,
	boolean = boolean,
	flag = flag,
	none = none,
	one_of = one_of,
	key_of = key_of,
	optional = optional,
	list = list,
	first = first,
	record = record,
})
