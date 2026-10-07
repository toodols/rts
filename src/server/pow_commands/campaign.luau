-- The game's own pow command of the campaign: re-timing the mission being played, for a mission that can be (its
-- handler's `retime`, server/missions/kit.luau). Finishing a mission and unlocking or relocking defs are every place's
-- (server_shared/pow_common.luau).
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local pow_types = require(ReplicatedStorage.Shared.pow_types)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local missions = require(ServerScriptService.Server.missions)

type Context = pow_builders.Context

return function(extras: pow_types.Extras)
	local commands = extras.commands

	commands.mission_timing = {
		description = "Re-times the mission being played, if it has anything timed (the counterattack's waves): the "
			.. "seconds to prepare before the first of it, and how many times as long the gaps after are. A prep "
			.. "shorter than has already gone brings the first at once. With no arguments the usual comes back.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Prep", type = "number" } } },
			{ returns = "nil", args = { { name = "Prep", type = "number" }, { name = "Pace", type = "number" } } },
		},
		server_run = function(context: Context)
			local prep: number? = context.args[1]
			local pace: number? = context.args[2]
			local ok, why = missions.retime(prep, pace)
			if ok == false then
				context:log({ type = "error", value = why })
				return
			end
			context:log({
				type = "info",
				value = `{missions.mission()}: {if prep ~= nil then prep else "the usual"} seconds to prepare, pace `
					.. `{if pace ~= nil then pace else 1}`,
			})
		end,
	}
end
