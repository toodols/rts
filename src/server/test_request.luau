--!strict
-- The Studio test this session was started to run, if it was. A Studio plugin (the Studio MCP's execute_luau, in the
-- Edit datamodel) starts a Run session with StudioTestService:ExecuteRunModeAsync(args); when `args.test` names a test,
-- the session runs that test instead of an ordinary game (see tests/init.luau). Anywhere else, a live server included,
-- there is no request, and the tests are never loaded.

local RunService = game:GetService "RunService"

-- The arguments the session was started with: `test`, the test's name, and whatever that test takes.
export type Request = { [string]: any }

local function read(): Request?
	if RunService:IsStudio() == false then
		return nil
	end
	-- the service is only there in Studio, so it is not asked for until now
	local ok, args = pcall(function(): any
		return game:GetService("StudioTestService"):GetTestArgs()
	end)
	if ok == false or typeof(args) ~= "table" or typeof(args.test) ~= "string" then
		return nil
	end
	return args
end

-- Ends the session a test was run in, handing `result` back to whoever started it: ExecuteRunModeAsync returns it.
local function finish(result: { [string]: any })
	game:GetService("StudioTestService"):EndTest(result)
end

return table.freeze({
	request = read(),
	finish = finish,
})
