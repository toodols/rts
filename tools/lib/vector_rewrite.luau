-- The one change the loader (loader.luau) makes to a module of the game's before it compiles it: the few things
-- a Roblox Vector3 answers that Luau's own vector does not (`.Magnitude`, `.Unit`, `:Dot(...)`, `:Cross(...)`,
-- `:Lerp(...)`, `:Abs()`, `:Min(...)`, `:Max(...)`, `:FuzzyEq(...)`) are rewritten into calls of `__vector`
-- (datatypes.vector_methods), which answer for a vector and hand anything else back to the thing itself. It has to be
-- rewritten: Luau's vector has no metatable a script can give it, and a Vector3 of the stand-in's own that was a table
-- would not be the 32-bit vector Roblox's is. Every line stays where it was.
--
-- The expression a property is read from is found by walking back over the tokens before it (`prefix_start`): a name
-- and whatever indexing and calls follow it, or a bracketed expression and what follows that. A shape it cannot read is
-- an error naming the file and the line, never a silent miscompile; tests/vector_rewrite_test.luau holds it to every
-- idiom the game uses, and to every module in src/.

local KEYWORDS = {
	["and"] = true,
	["break"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
	["continue"] = true,
}

local PROPERTIES = { Magnitude = true, Unit = true }
local METHODS = { Dot = true, Cross = true, Lerp = true, Abs = true, Min = true, Max = true, FuzzyEq = true }

type Token = { kind: string, text: string, start: number, finish: number }

-- The tokens of `source`, leaving out whitespace and comments. An interpolated string's text is a "string" token of
-- each piece, and the expressions between its braces are tokens like any others.
local function tokenize(source: string): { Token }
	local tokens: { Token } = {}
	local length = #source
	local at = 1
	-- how deep in braces each interpolated string being read is, innermost last
	local interpolation: { number } = {}

	local function push(kind: string, start: number, finish: number)
		table.insert(tokens, { kind = kind, text = string.sub(source, start, finish), start = start, finish = finish })
	end

	-- reads an interpolated string's text from `from` (just past a backtick or a closing brace) to the next brace
	-- that opens an expression, or the closing backtick
	local function read_interpolated(from: number): number
		local index = from
		while index <= length do
			local char = string.sub(source, index, index)
			if char == "\\" then
				index += 2
			elseif char == "`" then
				push("string", from, index)
				return index + 1
			elseif char == "{" then
				push("string", from, index)
				table.insert(interpolation, 0)
				return index + 1
			else
				index += 1
			end
		end
		error "an interpolated string runs off the end of the file"
	end

	while at <= length do
		local char = string.sub(source, at, at)
		if string.find(char, "%s") then
			at += 1
		elseif string.sub(source, at, at + 1) == "--" then
			local long = string.match(source, "^%-%-%[(=*)%[", at)
			if long ~= nil then
				local close = "]" .. long .. "]"
				local finish = string.find(source, close, at, true)
				at = if finish ~= nil then finish + #close else length + 1
			else
				local newline = string.find(source, "\n", at, true)
				at = if newline ~= nil then newline + 1 else length + 1
			end
		elseif string.find(char, "[%a_]") then
			local finish = (string.find(source, "[^%w_]", at) or length + 1) - 1
			push("name", at, finish)
			at = finish + 1
		elseif string.find(char, "%d") or (char == "." and string.find(string.sub(source, at + 1, at + 1), "%d")) then
			local finish = at
			while finish <= length do
				local next_char = string.sub(source, finish + 1, finish + 1)
				local this_char = string.sub(source, finish, finish)
				local exponent_sign = (next_char == "-" or next_char == "+") and string.find(this_char, "[eE]") ~= nil
				if string.find(next_char, "[%w_%.]") ~= nil or exponent_sign then
					finish += 1
				else
					break
				end
			end
			push("number", at, finish)
			at = finish + 1
		elseif char == '"' or char == "'" then
			local index = at + 1
			while index <= length do
				local c = string.sub(source, index, index)
				if c == "\\" then
					index += 2
				elseif c == char then
					break
				else
					index += 1
				end
			end
			push("string", at, index)
			at = index + 1
		elseif char == "`" then
			at = read_interpolated(at + 1)
		elseif char == "[" and string.match(source, "^%[=*%[", at) then
			local level = string.match(source, "^%[(=*)%[", at) :: string
			local close = "]" .. level .. "]"
			local finish = string.find(source, close, at, true)
			local last = if finish ~= nil then finish + #close - 1 else length
			push("string", at, last)
			at = last + 1
		elseif char == "{" and #interpolation > 0 then
			interpolation[#interpolation] += 1
			push("{", at, at)
			at += 1
		elseif char == "}" and #interpolation > 0 then
			if interpolation[#interpolation] == 0 then
				table.remove(interpolation)
				at = read_interpolated(at)
			else
				interpolation[#interpolation] -= 1
				push("}", at, at)
				at += 1
			end
		else
			local three = string.sub(source, at, at + 2)
			local two = string.sub(source, at, at + 1)
			if three == "..." or three == "..=" or three == "//=" then
				push(three, at, at + 2)
				at += 3
			elseif
				two == "=="
				or two == "~="
				or two == "<="
				or two == ">="
				or two == ".."
				or two == "::"
				or two == "->"
				or two == "+="
				or two == "-="
				or two == "*="
				or two == "/="
				or two == "%="
				or two == "^="
				or two == "//"
			then
				push(two, at, at + 1)
				at += 2
			else
				push(char, at, at)
				at += 1
			end
		end
	end
	return tokens
end

local CLOSERS = { [")"] = "(", ["]"] = "[", ["}"] = "{" }

-- The index of the first token of the expression that ends at token `last`, which the property or method after it
-- is read from: a name, and whatever indexing and calls follow it, or a bracketed expression and what follows it.
local function prefix_start(tokens: { Token }, last: number): number
	local index = last
	while true do
		local token = tokens[index]
		local open = CLOSERS[token.kind]
		if open ~= nil then
			local depth = 0
			local at = index
			while at >= 1 do
				local kind = tokens[at].kind
				if kind == token.kind then
					depth += 1
				elseif kind == open then
					depth -= 1
					if depth == 0 then
						break
					end
				end
				at -= 1
			end
			assert(at >= 1, "unbalanced brackets before a vector property")
			local before = tokens[at - 1]
			if open == "{" then
				-- a call with a table, f{...}
				index = at - 1
				continue
			end
			if
				before ~= nil
				and (
					(before.kind == "name" and KEYWORDS[before.text] == nil)
					or before.kind == ")"
					or before.kind == "]"
					or (before.kind == "string" and string.sub(before.text, -1) ~= "{")
				)
			then
				-- a call or an index on what is before it
				index = at - 1
				continue
			end
			return at
		elseif token.kind == "name" then
			local before = tokens[index - 1]
			if before ~= nil and (before.kind == "." or before.kind == ":") then
				index -= 2
				continue
			end
			return index
		elseif token.kind == "string" then
			-- a call with a string, f"..."; its function is before it
			index -= 1
			continue
		end
		error(`cannot tell what a vector property is read from, at "{token.text}"`)
	end
end

-- `prefix_start`, and where it fails, which file and line.
local function start_of(tokens: { Token }, last: number, source: string, module_name: string?): number
	local ok, start = pcall(prefix_start, tokens, last)
	if not ok then
		local line = #string.split(string.sub(source, 1, tokens[last].start), "\n")
		error(`{module_name or "a module"}:{line}: {start}`, 0)
	end
	return start
end

type Edit = { at: number, finish: number, text: string, order: number }

-- `source` (the module `module_name`, for what an error says) with every `.Magnitude`, `.Unit` and vector method call rewritten into a call of `__vector`.
local function rewrite(source: string, module_name: string?): string
	local ok, tokenized = pcall(tokenize, source)
	if not ok then
		error(`{module_name or "a module"}: {tokenized}`, 0)
	end
	local tokens: { Token } = tokenized
	local edits: { Edit } = {}
	for index = 2, #tokens - 1 do
		local token = tokens[index]
		local name = tokens[index + 1]
		if name.kind ~= "name" then
			continue
		end
		if token.kind == "." and PROPERTIES[name.text] then
			local start = start_of(tokens, index - 1, source, module_name)
			table.insert(
				edits,
				{ at = tokens[start].start, finish = -1, text = `__vector.{name.text}(`, order = index }
			)
			table.insert(edits, { at = token.start, finish = name.finish, text = ")", order = index })
		elseif
			token.kind == ":"
			and METHODS[name.text]
			and tokens[index + 2] ~= nil
			and tokens[index + 2].kind == "("
		then
			local start = start_of(tokens, index - 1, source, module_name)
			local open = tokens[index + 2]
			local empty = tokens[index + 3] ~= nil and tokens[index + 3].kind == ")"
			table.insert(
				edits,
				{ at = tokens[start].start, finish = -1, text = `__vector.{name.text}(`, order = index }
			)
			table.insert(
				edits,
				{ at = token.start, finish = open.finish, text = if empty then "" else ", ", order = index }
			)
		end
	end
	-- from the end back, so that each edit's place is still where it was; of two put in at the same place, the one
	-- for the later property goes in last, so that it ends up outside
	table.sort(edits, function(a, b)
		if a.at ~= b.at then
			return a.at > b.at
		end
		return a.order < b.order
	end)
	local result = source
	for _, edit in edits do
		if edit.finish < 0 then
			result = string.sub(result, 1, edit.at - 1) .. edit.text .. string.sub(result, edit.at)
		else
			result = string.sub(result, 1, edit.at - 1) .. edit.text .. string.sub(result, edit.finish + 1)
		end
	end
	return result
end

return table.freeze({
	rewrite = rewrite,
})
