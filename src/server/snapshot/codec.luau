--!strict
-- A graph of tables as a buffer, and back: what server/snapshot keeps the game in.
--
-- Every table is written once, however many places hold it, so what two parts of the game share (an entity that is in
-- the world and in a hold, a weapon keyed in two tables) is one table again once it is read back. What only defs make,
-- a def and every table inside it, is written as where it is found (`unit_defs.made`, then the keys down to it) and
-- read back as the very table the reader's own defs have there, since the game keys tables by weapons and defs and
-- tells them apart by what they are, not what they hold. Any other frozen table is a copy, frozen again once it is read.
--
-- Numbers are kept to the bit, Vector3s as the three 32-bit floats they are. A table's keys are written in one order,
-- whatever order its own history left them in (numbers, then strings, then booleans, then tables), so that the same
-- game writes the same bytes, and a table read back is filled in that order, so that the same bytes make tables that
-- iterate the same way wherever they are read.
--
-- A function, a thread or an Instance cannot be kept: what holds one says how to put it back itself, and writing one is
-- an error naming where it was found.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local MAGIC = "RTSSNAP1"

-- What each value is written as, by its first byte.
local TAG_FALSE = 0
local TAG_TRUE = 1
local TAG_NUMBER = 2
local TAG_INTEGER = 3
local TAG_STRING = 4
local TAG_TABLE = 5
local TAG_VECTOR3 = 6
local TAG_VECTOR2 = 7
local TAG_DEF = 8
local TAG_BUFFER = 9

-- A table's record starts with its flags.
local FLAG_FROZEN = 1

-- The kinds of def `unit_defs.made` lists, by the byte each is written as.
local MADE_KINDS: { [string]: number } = { def = 0, skinned = 1, wreck = 2 }

-- Where a table only defs make is found: which def, and the keys down to it from there.
type DefPath = { made: unit_defs.Made, keys: { string | number } }

-- Every table inside the defs made so far, by where each is first found, worked out again only once more defs have
-- been made.
local def_paths: { [any]: DefPath } = {}
local def_paths_made = -1

local function find_def_paths(): { [any]: DefPath }
	local made = unit_defs.made()
	if #made == def_paths_made then
		return def_paths
	end
	local found: { [any]: DefPath } = {}
	local function walk(value: any, entry: unit_defs.Made, keys: { string | number })
		if found[value] ~= nil then
			return
		end
		found[value] = { made = entry, keys = table.clone(keys) }
		local names: { string } = {}
		local numbers: { number } = {}
		for key, item in value do
			if type(item) == "table" then
				if type(key) == "string" then
					table.insert(names, key)
				elseif type(key) == "number" then
					table.insert(numbers, key)
				end
			end
		end
		table.sort(numbers)
		table.sort(names)
		for _, key in numbers do
			table.insert(keys, key)
			walk(value[key], entry, keys)
			table.remove(keys)
		end
		for _, key in names do
			table.insert(keys, key)
			walk(value[key], entry, keys)
			table.remove(keys)
		end
	end
	for _, entry in made do
		walk(entry.def, entry, {})
	end
	def_paths = found
	def_paths_made = #made
	return found
end

-- Writing ---------------------------------------------------------------------------------------------------------

type Writer = {
	data: buffer,
	at: number,
}

local function reserve(writer: Writer, size: number)
	local needed = writer.at + size
	local capacity = buffer.len(writer.data)
	if needed <= capacity then
		return
	end
	while capacity < needed do
		capacity *= 2
	end
	local grown = buffer.create(capacity)
	buffer.copy(grown, 0, writer.data, 0, writer.at)
	writer.data = grown
end

local function write_u8(writer: Writer, value: number)
	reserve(writer, 1)
	buffer.writeu8(writer.data, writer.at, value)
	writer.at += 1
end

local function write_u32(writer: Writer, value: number)
	reserve(writer, 4)
	buffer.writeu32(writer.data, writer.at, value)
	writer.at += 4
end

local function write_i32(writer: Writer, value: number)
	reserve(writer, 4)
	buffer.writei32(writer.data, writer.at, value)
	writer.at += 4
end

local function write_f32(writer: Writer, value: number)
	reserve(writer, 4)
	buffer.writef32(writer.data, writer.at, value)
	writer.at += 4
end

local function write_f64(writer: Writer, value: number)
	reserve(writer, 8)
	buffer.writef64(writer.data, writer.at, value)
	writer.at += 8
end

local function write_bytes(writer: Writer, bytes: string)
	reserve(writer, #bytes)
	buffer.writestring(writer.data, writer.at, bytes)
	writer.at += #bytes
end

-- The order keys of each kind go in: numbers, strings, booleans, then tables.
local KEY_RANKS: { [string]: number } = { number = 1, string = 2, boolean = 3, table = 4 }

-- `root`, and every table it reaches, as a buffer. `root` is a table.
local function encode(root: { [any]: any }): buffer
	local paths = find_def_paths()

	-- every table to be written, by the number it is written as, and the other way round
	local tables: { any } = {}
	local numbers: { [any]: number } = {}
	-- where each was first found, for saying where something that cannot be kept is: the table it was in, and the key
	local found_in: { [number]: number } = {}
	local found_at: { [number]: any } = {}
	-- every string, by the number it is written as, and the other way round
	local strings: { string } = {}
	local string_numbers: { [string]: number } = {}

	local function string_number(value: string): number
		local number = string_numbers[value]
		if number == nil then
			table.insert(strings, value)
			number = #strings
			string_numbers[value] = number
		end
		return number
	end

	local function where(number: number, key: any): string
		local keys = { tostring(key) }
		local at = number
		while at ~= nil and at > 1 do
			table.insert(keys, 1, tostring(found_at[at]))
			at = found_in[at]
		end
		return table.concat(keys, ".")
	end

	-- the number `value`, a table to be written in full, is written as, taking the next if it has none yet
	local function table_number(value: any, parent: number, key: any): number
		local number = numbers[value]
		if number == nil then
			if getmetatable(value) ~= nil then
				error(`snapshot: a table with a metatable cannot be kept, at {where(parent, key)}`)
			end
			table.insert(tables, value)
			number = #tables
			numbers[value] = number
			found_in[number] = parent
			found_at[number] = key
		end
		return number
	end

	local body: Writer = { data = buffer.create(65536), at = 0 }

	local function write_value(value: any, parent: number, key: any)
		local kind = typeof(value)
		if kind == "boolean" then
			write_u8(body, if value then TAG_TRUE else TAG_FALSE)
		elseif kind == "number" then
			if
				value == math.floor(value)
				and value >= -2147483648
				and value <= 2147483647
				and not (value == 0 and 1 / value < 0)
			then
				write_u8(body, TAG_INTEGER)
				write_i32(body, value)
			else
				write_u8(body, TAG_NUMBER)
				write_f64(body, value)
			end
		elseif kind == "string" then
			write_u8(body, TAG_STRING)
			write_u32(body, string_number(value))
		elseif kind == "Vector3" then
			write_u8(body, TAG_VECTOR3)
			write_f32(body, value.X)
			write_f32(body, value.Y)
			write_f32(body, value.Z)
		elseif kind == "Vector2" then
			-- as the doubles it hands out, which are the 32-bit floats it holds in Roblox and whatever it holds elsewhere
			write_u8(body, TAG_VECTOR2)
			write_f64(body, value.X)
			write_f64(body, value.Y)
		elseif kind == "buffer" then
			write_u8(body, TAG_BUFFER)
			local size = buffer.len(value)
			write_u32(body, size)
			reserve(body, size)
			buffer.copy(body.data, body.at, value, 0, size)
			body.at += size
		elseif kind == "table" then
			local path = paths[value]
			if path ~= nil then
				write_u8(body, TAG_DEF)
				write_u8(body, MADE_KINDS[path.made.kind])
				write_u32(body, string_number(path.made.name))
				write_u32(body, string_number(path.made.skin or ""))
				write_u8(body, #path.keys)
				for _, step in path.keys do
					write_value(step, parent, key)
				end
			else
				write_u8(body, TAG_TABLE)
				write_u32(body, table_number(value, parent, key))
			end
		else
			error(`snapshot: a {kind} cannot be kept, at {where(parent, key)}`)
		end
	end

	-- the order a table's keys are written in, as KEY_RANKS says, and within tables: defs by where they are, then
	-- tables already numbered by number, then the rest by their `id` if they have one, which entities do
	local function key_before(a: any, b: any): boolean
		local rank_a, rank_b = KEY_RANKS[type(a)], KEY_RANKS[type(b)]
		if rank_a ~= rank_b then
			return rank_a < rank_b
		end
		if rank_a == 1 or rank_a == 2 then
			return a < b
		elseif rank_a == 3 then
			return a == false and b == true
		end
		local path_a, path_b = paths[a], paths[b]
		if path_a ~= nil or path_b ~= nil then
			if path_a == nil or path_b == nil then
				return path_a ~= nil
			end
			local text_a = `{path_a.made.kind}/{path_a.made.skin or ""}/{path_a.made.name}/{table.concat(
				path_a.keys :: { any },
				"/"
			)}`
			local text_b = `{path_b.made.kind}/{path_b.made.skin or ""}/{path_b.made.name}/{table.concat(
				path_b.keys :: { any },
				"/"
			)}`
			return text_a < text_b
		end
		local number_a, number_b = numbers[a], numbers[b]
		if number_a ~= nil or number_b ~= nil then
			if number_a == nil or number_b == nil then
				return number_a ~= nil
			end
			return number_a < number_b
		end
		local id_a, id_b = rawget(a, "id"), rawget(b, "id")
		if type(id_a) == "number" and type(id_b) == "number" then
			return id_a < id_b
		end
		return type(id_a) == "number" and type(id_b) ~= "number"
	end

	table_number(root, 0, "root")
	local next_table = 1
	while next_table <= #tables do
		local value = tables[next_table]
		local keys = {}
		for key in value do
			local key_kind = type(key)
			if KEY_RANKS[key_kind] == nil then
				error(`snapshot: a {typeof(key)} key cannot be kept, at {where(next_table, key)}`)
			end
			table.insert(keys, key)
		end
		table.sort(keys, key_before)
		write_u8(body, if table.isfrozen(value) then FLAG_FROZEN else 0)
		write_u32(body, #keys)
		for _, key in keys do
			write_value(key, next_table, key)
			write_value(value[key], next_table, key)
		end
		next_table += 1
	end

	local out: Writer = { data = buffer.create(body.at + 64), at = 0 }
	write_bytes(out, MAGIC)
	write_u32(out, #strings)
	for _, text in strings do
		write_u32(out, #text)
		write_bytes(out, text)
	end
	write_u32(out, #tables)
	reserve(out, body.at)
	buffer.copy(out.data, out.at, body.data, 0, body.at)
	out.at += body.at
	local exact = buffer.create(out.at)
	buffer.copy(exact, 0, out.data, 0, out.at)
	return exact
end

-- Reading ---------------------------------------------------------------------------------------------------------

local MADE_BY_BYTE: { [number]: string } = { [0] = "def", [1] = "skinned", [2] = "wreck" }

-- The table `encode` was handed, with everything it reached, made afresh from `data`.
local function decode(data: buffer): { [any]: any }
	local at = 0
	local function read_u8(): number
		local value = buffer.readu8(data, at)
		at += 1
		return value
	end
	local function read_u32(): number
		local value = buffer.readu32(data, at)
		at += 4
		return value
	end

	assert(buffer.len(data) >= #MAGIC and buffer.readstring(data, 0, #MAGIC) == MAGIC, "snapshot: not a snapshot")
	at = #MAGIC
	local string_count = read_u32()
	local strings: { string } = table.create(string_count)
	for index = 1, string_count do
		local size = read_u32()
		strings[index] = buffer.readstring(data, at, size)
		at += size
	end
	local table_count = read_u32()
	local tables: { any } = table.create(table_count)
	for index = 1, table_count do
		tables[index] = {}
	end
	local frozen: { any } = {}

	local function read_value(): any
		local tag = read_u8()
		if tag == TAG_FALSE then
			return false
		elseif tag == TAG_TRUE then
			return true
		elseif tag == TAG_INTEGER then
			local value = buffer.readi32(data, at)
			at += 4
			return value
		elseif tag == TAG_NUMBER then
			local value = buffer.readf64(data, at)
			at += 8
			return value
		elseif tag == TAG_STRING then
			return strings[read_u32()]
		elseif tag == TAG_TABLE then
			return tables[read_u32()]
		elseif tag == TAG_VECTOR3 then
			local x = buffer.readf32(data, at)
			local y = buffer.readf32(data, at + 4)
			local z = buffer.readf32(data, at + 8)
			at += 12
			return Vector3.new(x, y, z)
		elseif tag == TAG_VECTOR2 then
			local x = buffer.readf64(data, at)
			local y = buffer.readf64(data, at + 8)
			at += 16
			return Vector2.new(x, y)
		elseif tag == TAG_BUFFER then
			local size = read_u32()
			local value = buffer.create(size)
			buffer.copy(value, 0, data, at, size)
			at += size
			return value
		elseif tag == TAG_DEF then
			local kind = MADE_BY_BYTE[read_u8()]
			local name = strings[read_u32()]
			local skin = strings[read_u32()]
			local def: any = if kind == "def"
				then unit_defs.get(name)
				elseif kind == "skinned" then unit_defs.skinned(name, skin)
				else unit_defs.wreck_of(name)
			for _ = 1, read_u8() do
				def = def[read_value()]
				assert(def ~= nil, `snapshot: no such part of the def "{name}" here`)
			end
			return def
		end
		error(`snapshot: unknown tag {tag} at byte {at - 1}`)
	end

	for index = 1, table_count do
		local value = tables[index]
		local flags = read_u8()
		for _ = 1, read_u32() do
			local key = read_value()
			value[key] = read_value()
		end
		if bit32.band(flags, FLAG_FROZEN) ~= 0 then
			table.insert(frozen, value)
		end
	end
	assert(at == buffer.len(data), "snapshot: bytes left over")
	for _, value in frozen do
		table.freeze(value)
	end
	return tables[1]
end

-- Where `value` is found in the defs, as text ("skinned/golden/grunt/weapons/1"), if it is a table only defs make.
local function def_path(value: any): string?
	local path = find_def_paths()[value]
	if path == nil then
		return nil
	end
	local keys: { string } = { path.made.kind, path.made.skin or "", path.made.name }
	for _, key in path.keys do
		table.insert(keys, tostring(key))
	end
	return table.concat(keys, "/")
end

return table.freeze({
	encode = encode,
	decode = decode,
	def_path = def_path,
})
