--!strict
-- The game's tests, each a scenario played on the real simulation and checked. They are run in a Studio session a
-- Studio plugin starts to run one (the Studio MCP's execute_luau, in the Edit datamodel), and headless by the arena's
-- stand-in of the engine (tools/headless_tests). Only a session started to run a test loads them (session_config.luau).
--
--     local result = game:GetService("StudioTestService"):ExecuteRunModeAsync({ test = "bombing" })
--
-- `result` is a table: `ok`, and either `error` or what the test found; a check's `pass` says whether it passed, and a
-- diagnostic, which only reports, says `diagnostic`. Nothing is set on or added to the place, and nothing has to be
-- read back out of the output, so a test leaves nothing behind.
--
-- Any test can be run on another map than its usual by passing `preset`, a name from map_presets:
--
--     ExecuteRunModeAsync({ test = "map", preset = "rifted" })
--
-- A test owns the simulation's clock (harness.luau). The session it runs in is `session_for`'s, in Studio and headless
-- alike: scavengers off unless the test hands in a match, nobody joining, the rocks and trees the map starts with taken
-- away unless the test is started with `scenery = true`, so the world holds only what the test makes, and whatever the
-- game leaves to chance rolled from `random_seed`, or the map's seed if it gives none, so the test plays the same every
-- time, wherever it is run. Once it is over, everything is taken away again. The one test on the server's own loop is
-- "benchmark", which runs /benchmark as it is and hands back its report.
--
-- What a run of a test comes to, however it is run, is `status_of`'s to say.

local ServerScriptService = game:GetService "ServerScriptService"

local test_request = require(ServerScriptService.Server.test_request)

local harness = require(script.harness)
local ai = require(script.ai)
local aircraft = require(script.aircraft)
local campaign = require(script.campaign)
local construction = require(script.construction)
local economy = require(script.economy)
local maps = require(script.maps)
local matches = require(script.matches)
local movement = require(script.movement)
local naval = require(script.naval)
local performance = require(script.performance)
local piloting = require(script.piloting)
local scavengers = require(script.scavengers)
local transport = require(script.transport)
local weapons = require(script.weapons)

export type Args = harness.Args
export type Findings = harness.Findings
-- What a run of a test comes to: a check that passed or failed, a diagnostic, one that could not run, or one that
-- needs Studio, run where there is none.
export type Status = "PASS" | "FAIL" | "DIAG" | "ERROR" | "SKIP"
type Test = harness.Test
type Clock = harness.Clock

local AREAS: { { [string]: Test } } = {
	ai,
	aircraft,
	campaign,
	construction,
	economy,
	maps,
	matches,
	movement,
	naval,
	performance,
	piloting,
	scavengers,
	transport,
	weapons,
}

-- Every test, by name.
local TESTS: { [string]: Test } = {}
for _, area in AREAS do
	for name, test in area do
		assert(TESTS[name] == nil, `two tests are called "{name}"`)
		TESTS[name] = test
	end
end
table.freeze(TESTS)

-- Every test's name, in order.
local function names(): { string }
	local found: { string } = {}
	for name in TESTS do
		table.insert(found, name)
	end
	table.sort(found)
	return found
end

-- The test `name` names, if there is one.
local function get(name: string): Test?
	return TESTS[name]
end

-- What test `request.test` is started with: the test's own defaults, and over them what it was asked.
local function args_for(request: Args): Args
	local test = TESTS[request.test]
	local args: Args = if test ~= nil and test.defaults ~= nil then table.clone(test.defaults) else {}
	for key, value in request do
		args[key] = value
	end
	return args
end

-- The session test `request.test` runs in (session_config.luau's `unplayed`): on the map it asks for (`preset`), or its
-- match's, or the usual; with the match it hands in, if any; keeping the scenery if it asks to; rolled from its
-- `random_seed`, or else the map's seed.
local function session_for(request: Args): { [string]: any }
	local args = args_for(request)
	return {
		match = args.match,
		preset = if typeof(args.preset) == "string" then args.preset else nil,
		scenery = args.scenery == true,
		random_seed = if typeof(args.random_seed) == "number" then args.random_seed else nil,
		seeded = true,
		test = args,
	}
end

-- What `result`, what a run of a test handed back, comes to.
local function status_of(result: Findings): Status
	if result.skipped ~= nil then
		return "SKIP"
	elseif result.ok ~= true then
		return "ERROR"
	elseif result.diagnostic == true then
		return "DIAG"
	end
	return if result.pass == true then "PASS" else "FAIL"
end

-- What the session hands back for a run of `test`: what it found, or why it could not say. A check that says nothing
-- about whether it passed has not been checked, and a diagnostic that passes judgement is not one.
local function verdict(test: Test, ran: boolean, findings: any): Findings
	if ran == false then
		return { ok = false, error = tostring(findings) }
	end
	if typeof(findings) ~= "table" then
		return { ok = false, error = "the test found nothing" }
	end
	-- a check run with arguments it cannot judge by says so, and only reports
	if test.diagnostic == true or findings.diagnostic == true then
		if findings.pass ~= nil then
			return {
				ok = false,
				error = "a diagnostic passes no judgement, but this one returned a pass",
				found = findings,
			}
		end
		findings.diagnostic = true
	elseif typeof(findings.pass) ~= "boolean" then
		return { ok = false, error = "the test returned no pass", found = findings }
	end
	findings.ok = true
	return findings
end

-- Runs test `args.test` on `clock` and returns what the session hands back for it.
local function run(args: Args, clock: Clock): Findings
	local test = TESTS[args.test]
	if test == nil then
		return { ok = false, error = `no test "{args.test}"; there are {table.concat(names(), ", ")}` }
	end
	harness.start(clock)
	local ran, findings = pcall(test.run, args)
	local sim_seconds = harness.round(harness.now(), 2)
	-- what the test left on the map goes, whatever became of it
	pcall(harness.clear_world)
	local result = verdict(test, ran, findings)
	result.sim_seconds = sim_seconds
	return result
end

-- Starts the test a Studio session was started to run, `args` (see `args_for`), which hands what it found back through
-- StudioTestService once it is done. `step` is one step of the simulation. Returns whether the test steps the
-- simulation itself, so that the server's own loop must not.
local function begin(args: Args, step: (number) -> ()): boolean
	local test = TESTS[args.test]
	if test ~= nil and test.on_loop == true then
		task.spawn(function()
			local ran, findings = pcall(test.run, args)
			test_request.finish(verdict(test, ran, findings))
		end)
		return false
	end
	task.spawn(function()
		test_request.finish(run(args, {
			step = step,
			settle = function()
				task.wait()
			end,
		}))
	end)
	return test ~= nil
end

return table.freeze({
	names = names,
	get = get,
	args_for = args_for,
	session_for = session_for,
	status_of = status_of,
	run = run,
	begin = begin,
})
