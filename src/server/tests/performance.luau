--!strict
-- How fast the simulation runs: /benchmark (server/benchmark.luau), run as it is, on the server's own loop, which it
-- warps, and its report handed back.

local ServerScriptService = game:GetService "ServerScriptService"

local benchmark = require(ServerScriptService.Server.benchmark)

local harness = require(script.Parent.harness)

type Args = harness.Args
type Findings = harness.Findings
type Test = harness.Test

local function run_benchmark(_args: Args): Findings
	local report = ""
	benchmark.run(function(text: string)
		report = text
	end)
	return { report = report }
end

local TESTS: { [string]: Test } = {
	benchmark = {
		run = run_benchmark,
		diagnostic = true,
		on_loop = true,
		studio_only = "warps the server's own loop, which only a Studio session runs",
	},
}

return table.freeze(TESTS)
