-- pow command-bar types for things picked by name out of a fixed list, such as a map or a skin, for the pow extensions of
-- every place (the game's server/pow_shared_ext.luau, the lobby's lobby/server/pow_shared_ext.luau).

-- A pow type called `type_name` that takes any of `names`, suggesting them, and refuses anything else, saying what
-- there is. `names` is sorted in place.
local function named(type_name: string, description: string, names: { string }): { [string]: any }
	table.sort(names)
	local function as_name(name: string): { ok: string?, err: string? }
		if table.find(names, name) ~= nil then
			return { ok = name }
		end
		return { err = `there is no {type_name} "{name}"; there are {table.concat(names, ", ")}` }
	end
	return {
		name = type_name,
		description = description,
		autocomplete_simple = names,
		coerce_expression = function(expression: any): { ok: string?, err: string? }
			if expression.type == "string" then
				return as_name(expression.value)
			end
			return { err = `cannot coerce {expression.type} to {type_name}` }
		end,
		coerce_value = function(value: any): { ok: string?, err: string? }
			if typeof(value) == "string" then
				return as_name(value)
			end
			return { err = `cannot coerce {typeof(value)} to {type_name}` }
		end,
	}
end

return table.freeze({
	named = named,
})
