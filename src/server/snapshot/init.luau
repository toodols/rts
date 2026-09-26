--!strict
-- The whole game as it stands between two steps, as a buffer (`capture`), and the game put back to one (`restore`), so
-- that it plays on from there exactly as it would have: the same steps, bit for bit.
--
-- Each part of the game that keeps anything from one step to the next says what it keeps and how to put it back
-- (`keep`), under a name of its own. What it keeps is plain data (tables, numbers, strings, booleans, Vector3s,
-- Vector2s, buffers and defs; see codec.luau), and anything it shares with another part (an entity, a weapon) is still
-- shared once it is read back. Putting it back hands each part fresh tables, made from the bytes the same way wherever
-- they are read, so a game put back iterates its tables in the same order as any other copy put back from the same
-- snapshot. What is only worked out from what is kept (a grid of where things stand, what can be walked where) is
-- worked out again once everything is back (`rebuild`).
--
-- A game is only captured or put back between steps, never during one.

local codec = require(script.codec)

type Keeper = {
	capture: () -> any,
	restore: (saved: any) -> (),
}

local keepers: { [string]: Keeper } = {}
local rebuilders: { [string]: () -> () } = {}

-- Keeps what `capture` hands back, under `name`, and puts it back with `restore`, which is handed a copy of it made
-- afresh. Once, as the module that keeps it loads.
local function keep(name: string, capture: () -> any, restore: (saved: any) -> ())
	assert(keepers[name] == nil, `snapshot: "{name}" is kept twice`)
	keepers[name] = { capture = capture, restore = restore }
end

-- Runs `run` once a game has been put back and everything is back, to work out again what is worked out from it.
local function rebuild(name: string, run: () -> ())
	assert(rebuilders[name] == nil, `snapshot: "{name}" is rebuilt twice`)
	rebuilders[name] = run
end

local function sorted_names(of: { [string]: any }): { string }
	local names = {}
	for name in of do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

-- The game as it stands, as a buffer.
local function capture(): buffer
	local root: { [string]: any } = {}
	for _, name in sorted_names(keepers) do
		local saved = keepers[name].capture()
		-- nothing kept is kept as false, so that it is still there to be put back
		root[name] = if saved == nil then false else saved
	end
	return codec.encode(root)
end

-- Puts the game back to `data`, a buffer `capture` made: every part in turn, by name, then everything worked out from
-- them.
local function restore(data: buffer)
	local root = codec.decode(data)
	for _, name in sorted_names(keepers) do
		local saved = root[name]
		assert(saved ~= nil, `snapshot: nothing was kept for "{name}"`)
		keepers[name].restore(if saved == false then nil else saved)
	end
	for name in root do
		assert(keepers[name] ~= nil, `snapshot: "{name}" was kept, and nothing here puts it back`)
	end
	for _, name in sorted_names(rebuilders) do
		rebuilders[name]()
	end
end

-- The game as it stands, as a buffer, with the game put back to it at once: from here on this game and every copy put
-- back from the same buffer play on exactly alike. A game only `capture`d plays on as it was, with its tables as their
-- history left them, and those can iterate in another order than the ones a copy is made with; so what has to stay in
-- step with its copies (a game forked in two) is `take`n.
local function take(): buffer
	local data = capture()
	restore(data)
	return data
end

-- A buffer's bytes as a number, for telling two apart in a line of text.
local function checksum(value: buffer): number
	local sum = 0
	for at = 0, buffer.len(value) - 1 do
		sum = (sum * 31 + buffer.readu8(value, at)) % 2147483647
	end
	return sum
end

-- A snapshot as lines of text, one for each value, each named by the keys down to it from the part that kept it, in
-- the order they were written: for telling where two snapshots differ. A table met again is named by where it was
-- first met, and a def's by where it is in the defs.
local function describe(data: buffer): { string }
	local root = codec.decode(data)
	local lines: { string } = {}
	local first_met: { [any]: string } = {}
	local function key_text(key: any): string
		if type(key) == "table" then
			local def = codec.def_path(key)
			return if def ~= nil then `<{def}>` else first_met[key] or "<table>"
		end
		return tostring(key)
	end
	local function value_text(value: any): string
		if type(value) == "table" then
			local def = codec.def_path(value)
			return if def ~= nil then `<{def}>` else `@{first_met[value]}`
		elseif type(value) == "number" then
			return string.format("%.17g", value)
		elseif typeof(value) == "Vector3" then
			return string.format("(%.9g, %.9g, %.9g)", value.X, value.Y, value.Z)
		elseif type(value) == "buffer" then
			return `buffer of {buffer.len(value)} bytes, {checksum(value)}`
		end
		return tostring(value)
	end
	local queue: { { value: any, path: string } } = {}
	for _, name in sorted_names(root) do
		if type(root[name]) == "table" then
			first_met[root[name]] = name
			table.insert(queue, { value = root[name], path = name })
		else
			table.insert(lines, `{name} = {value_text(root[name])}`)
		end
	end
	local at = 1
	while at <= #queue do
		local item = queue[at]
		at += 1
		local keys = {}
		for key in item.value do
			table.insert(keys, key)
		end
		table.sort(keys, function(a: any, b: any): boolean
			if type(a) == "number" and type(b) == "number" then
				return a < b
			end
			return type(a) .. key_text(a) < type(b) .. key_text(b)
		end)
		for _, key in keys do
			local value = item.value[key]
			local path = `{item.path}.{key_text(key)}`
			if type(value) == "table" and first_met[value] == nil and codec.def_path(value) == nil then
				first_met[value] = path
				table.insert(queue, { value = value, path = path })
			else
				table.insert(lines, `{path} = {value_text(value)}`)
			end
		end
	end
	return lines
end

return table.freeze({
	keep = keep,
	rebuild = rebuild,
	capture = capture,
	restore = restore,
	take = take,
	describe = describe,
})
