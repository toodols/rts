-- This game's pow types, which the command bar on the client needs as much as the server does. pow copies this
-- module into ReplicatedStorage and runs it on both sides.
--
-- pow calls its extension modules to let them register types and commands, so this one returns a function rather
-- than the dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local map_presets = require(ReplicatedStorage.Shared.map_presets)

-- Every map there is, by name, in order.
local function map_names(): { string }
	local names = {}
	for name in map_presets.presets do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

return function(extras: { types: { [string]: any } })
	local names = map_names()

	local function as_map(name: string): { ok: string?, err: string? }
		if map_presets.presets[name] ~= nil then
			return { ok = name }
		end
		return { err = `there is no map "{name}"; there are {table.concat(names, ", ")}` }
	end

	-- One of map_presets' maps, by name.
	extras.types.map = {
		name = "map",
		description = "A map, by name",
		autocomplete_simple = names,
		coerce_expression = function(expression: any): { ok: string?, err: string? }
			if expression.type == "string" then
				return as_map(expression.value)
			end
			return { err = `cannot coerce {expression.type} to map` }
		end,
		coerce_value = function(value: any): { ok: string?, err: string? }
			if typeof(value) == "string" then
				return as_map(value)
			end
			return { err = `cannot coerce {typeof(value)} to map` }
		end,
	}
end
