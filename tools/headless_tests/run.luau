-- The game's tests (src/server/tests), headless: run by lune on the stand-in of the Roblox engine (tools/lib), the
-- same game a Studio session plays, from the repository's root.
--
--     lune run tools/headless_tests/run.luau <test> ['<json args>']   one test; its result, as JSON, on the last line,
--                                                                    exiting with 1 if it failed or could not run
--     lune run tools/headless_tests/run.luau all [--workers n] [--out dir] [--only a,b,...]
--     lune run tools/headless_tests/run.luau list
--
-- A test's args are what `{ test = name, ... }` takes in Studio (see src/server/tests/init.luau); its own defaults are
-- under them. `all` runs every test that can run headless, each in a process of its own as a Studio session is, several
-- at once, and prints a line for each: PASS or FAIL for a check, DIAG for a diagnostic, ERROR for one that failed to run
-- and SKIP for one that needs Studio, with why. It exits with 1 if anything failed or errored. `--out` keeps each test's
-- full result there as <test>.json; a failure's result is printed after its line either way.

local DateTime = require "@lune/datetime"
local fs = require "@lune/fs"
local process = require "@lune/process"
local serde = require "@lune/serde"
local stdio = require "@lune/stdio"
local task = require "@lune/task"

local session = require "../lib/session"

local root = process.cwd
-- Seconds of real time, which os.clock (this process's own time) is not while it waits on the tests' processes.
local function wall_clock(): number
	return DateTime.now().unixTimestampMillis / 1000
end

-- How much of a failed test's result is printed after its line.
local PRINTED_RESULT_CHARACTERS = 4000

-- `value` as something JSON can hold: a table with keys that are not a list's has them as strings, numbers too big for
-- JSON are strings, and anything that is not a plain value is its tostring.
local function plain(value: any): any
	local kind = typeof(value)
	if kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return tostring(value)
		end
		return value
	elseif kind == "string" or kind == "boolean" or kind == "nil" then
		return value
	elseif kind == "table" then
		local count = 0
		for _ in value do
			count += 1
		end
		if count > 0 and count == #value then
			local list = {}
			for index, item in value do
				list[index] = plain(item)
			end
			return list
		end
		local map = {}
		for key, item in value do
			map[tostring(key)] = plain(item)
		end
		return map
	end
	return tostring(value)
end

local function encode(value: any): string
	return serde.encode("json", plain(value))
end

-- Runs test `name` with `given` over its defaults in this process, and returns its result.
local function run_one(name: string, given: { [string]: any }): { [string]: any }
	session.load(root)
	local tests = session.server "tests"
	local test = tests.get(name)
	if test == nil then
		return { ok = false, error = `no test "{name}"; there are {table.concat(tests.names(), ", ")}` }
	end
	if test.studio_only ~= nil then
		return { ok = false, skipped = test.studio_only }
	end
	local request = table.clone(given)
	request.test = name
	local unplayed = tests.session_for(request)
	local game = session.start({ root = root, unplayed = unplayed })
	return tests.run(unplayed.test, {
		step = function(_delta: number)
			game.advance(1)
		end,
		settle = function()
			game.advance(0)
		end,
	})
end

-- The flags after `all`: `--workers n`, `--out dir`, `--only a,b`.
local function flags(from: number): { [string]: string }
	local found = {}
	local index = from
	while index <= #process.args do
		local flag = string.match(process.args[index], "^%-%-(.+)$")
		if flag ~= nil then
			found[flag] = process.args[index + 1] or ""
			index += 2
		else
			index += 1
		end
	end
	return found
end

-- Every test's name and how it runs, without starting a session.
local function catalogue(): { { name: string, studio_only: string?, diagnostic: boolean } }
	session.load(root)
	local tests = session.server "tests"
	local list = {}
	for _, name in tests.names() do
		local test = tests.get(name)
		table.insert(list, { name = name, studio_only = test.studio_only, diagnostic = test.diagnostic == true })
	end
	return list
end

local function run_all(options: { [string]: string }): boolean
	local workers = tonumber(options.workers) or 8
	local only: { [string]: boolean }? = nil
	if options.only ~= nil then
		only = {}
		for _, name in string.split(options.only, ",") do
			(only :: { [string]: boolean })[name] = true
		end
	end
	if options.out ~= nil then
		fs.writeDir(options.out)
	end
	local queue = {}
	for _, entry in catalogue() do
		if only ~= nil and only[entry.name] == nil then
			continue
		end
		if entry.studio_only ~= nil then
			print(`SKIP  {entry.name}: needs Studio ({entry.studio_only})`)
			continue
		end
		table.insert(queue, entry.name)
	end

	local counts = { PASS = 0, FAIL = 0, DIAG = 0, ERROR = 0 }
	local running = 0
	local started = wall_clock()
	local tests = session.server "tests"
	local function finish(name: string, seconds: number, output: string)
		local last = string.match(output, "([^\n]*)\n?$") or ""
		local ok, result = pcall(serde.decode, "json", last)
		if ok == false or typeof(result) ~= "table" then
			result = { ok = false, error = `no result: {string.sub(output, -PRINTED_RESULT_CHARACTERS)}` }
		end
		local status = tests.status_of(result)
		counts[status] += 1
		print(`{status}  {name} ({math.round(seconds)} s)`)
		if status == "FAIL" or status == "ERROR" then
			print(`      {string.sub(encode(result), 1, PRINTED_RESULT_CHARACTERS)}`)
		end
		if options.out ~= nil then
			fs.writeFile(`{options.out}/{name}.json`, encode(result))
		end
	end
	local next_index = 1
	local function worker()
		while next_index <= #queue do
			local name = queue[next_index]
			next_index += 1
			running += 1
			local began = wall_clock()
			local child = process.exec("lune", { "run", "tools/headless_tests/run.luau", name }, { cwd = root })
			finish(name, wall_clock() - began, child.stdout .. child.stderr)
			running -= 1
		end
	end
	for _ = 1, math.min(workers, #queue) do
		task.spawn(worker)
	end
	repeat
		task.wait(0.1)
	until next_index > #queue and running == 0
	print(
		`{counts.PASS} passed, {counts.FAIL} failed, {counts.ERROR} errored, {counts.DIAG} diagnostics`
			.. ` in {math.round(wall_clock() - started)} s`
	)
	return counts.FAIL == 0 and counts.ERROR == 0
end

local command = process.args[1]
if command == nil then
	stdio.ewrite "usage: lune run tools/headless_tests/run.luau <test> ['<json args>'] | all [--workers n] [--out dir] [--only a,b] | list\n"
	process.exit(2)
elseif command == "list" then
	for _, entry in catalogue() do
		local how = if entry.studio_only ~= nil
			then `studio only: {entry.studio_only}`
			elseif entry.diagnostic then "diagnostic"
			else "check"
		print(`{entry.name}  ({how})`)
	end
elseif command == "all" then
	process.exit(if run_all(flags(2)) then 0 else 1)
else
	local given = if process.args[2] ~= nil then serde.decode("json", process.args[2]) else {}
	local ok, result = pcall(run_one, command, given)
	if ok == false then
		result = { ok = false, error = tostring(result) }
	end
	print(encode(result))
	local status = session.server("tests").status_of(result)
	process.exit(if status == "FAIL" or status == "ERROR" then 1 else 0)
end
