-- Checks the loader's rewrite of Vector3's properties and methods (tools/lib/vector_rewrite.luau): each idiom the game's
-- source uses comes out as the call it should, what is not a vector's property is left alone, a shape it cannot read
-- is an error naming the file and line, and every module in src/ rewrites and still compiles. Run with
-- `lune run tools/lib/tests/vector_rewrite_test.luau` from the repository's root.

local fs = require "@lune/fs"
local luau = require "@lune/luau"

local vector_rewrite = require "../vector_rewrite"

local CASES: { { string } } = {
	{ "local d = v.Magnitude", "local d = __vector.Magnitude(v)" },
	{ "local u = (a - b).Unit", "local u = __vector.Unit((a - b))" },
	{ "local d = unit.position.Magnitude", "local d = __vector.Magnitude(unit.position)" },
	{ "local d = list[i].position.Magnitude", "local d = __vector.Magnitude(list[i].position)" },
	{ "local d = f(x).Magnitude", "local d = __vector.Magnitude(f(x))" },
	{ "local d = a:Dot(b)", "local d = __vector.Dot(a, b)" },
	{ "local d = a:Abs()", "local d = __vector.Abs(a)" },
	{ "local d = (a - b).Unit:Dot(c)", "local d = __vector.Dot(__vector.Unit((a - b)), c)" },
	{ "local d = a.Unit.Magnitude", "local d = __vector.Magnitude(__vector.Unit(a))" },
	{ "local s = `{v.Magnitude}`", "local s = `{__vector.Magnitude(v)}`" },
	{ "local d = -v.Magnitude", "local d = -__vector.Magnitude(v)" },
	{ "return v.Magnitude > 1 and w.Unit", "return __vector.Magnitude(v) > 1 and __vector.Unit(w)" },
	-- what only looks like one
	{ 'local s = "a.Magnitude"', 'local s = "a.Magnitude"' },
	{ "-- v.Magnitude", "-- v.Magnitude" },
	{ "local t = { Magnitude = 1 }", "local t = { Magnitude = 1 }" },
	{ "local m = a:Dotty(b)", "local m = a:Dotty(b)" },
}

local failures = 0
for _, case in CASES do
	local got = vector_rewrite.rewrite(case[1], "case")
	if got ~= case[2] then
		failures += 1
		print(`FAIL: {case[1]}\n  got      {got}\n  expected {case[2]}`)
	end
end

-- a shape it cannot read names the file and the line
local ok, problem = pcall(vector_rewrite.rewrite, "local a = 1\nlocal b = ).Magnitude", "broken.luau")
if ok or string.find(tostring(problem), "broken.luau:2", 1, true) == nil then
	failures += 1
	print(`FAIL: an unreadable shape should be an error at broken.luau:2, got {problem}`)
end

-- every module of the game's
local checked = 0
local function visit(directory: string)
	for _, name in fs.readDir(directory) do
		local path = `{directory}/{name}`
		if fs.isDir(path) then
			visit(path)
		elseif string.match(name, "%.luau?$") then
			local done, result = pcall(function()
				return luau.compile(vector_rewrite.rewrite(fs.readFile(path), path))
			end)
			checked += 1
			if not done then
				failures += 1
				print(`FAIL: {path}: {result}`)
			end
		end
	end
end
visit "src"

print(`{#CASES} cases, {checked} modules, {failures} failures`)
if failures > 0 then
	error "the vector rewrite is wrong"
end
