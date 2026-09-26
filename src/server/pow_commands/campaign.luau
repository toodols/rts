-- The pow commands of the campaign: unlocking what it keeps locked, or locking it again, saved (see
-- server_shared/campaign_session.luau), and re-timing the mission being played, for a mission that can be (its
-- handler's `retime`, server/missions/kit.luau). Finishing a mission is mission_complete (server_shared/pow_common.luau).
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local campaign = require(ReplicatedStorage.Shared.campaign)
local pow_types = require(ReplicatedStorage.Shared.pow_types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local campaign_session = require(ServerScriptService.ServerShared.campaign_session)
local pow_builders = require(ServerScriptService.ServerShared.pow_builders)
local pow_common = require(ServerScriptService.ServerShared.pow_common)

local missions = require(ServerScriptService.Server.missions)

type Context = pow_builders.Context

-- Every def that can be locked in the campaign.
local function lockable_defs(): { string }
	local _, locked = pow_common.split_unlocks({})
	return locked
end

return function(extras: pow_types.Extras)
	local commands = extras.commands

	commands.unlock_def = {
		description = "Unlocks a def in the campaign for you, or for the player given, saved. To unlock everything, "
			.. "unlock_all.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Def", type = "unit" } } },
			{ returns = "nil", args = { { name = "Def", type = "unit" }, { name = "Player", type = "player" } } },
		},
		server_run = function(context: Context)
			local player = pow_builders.target_player(context, 2)
			local wanted = context.args[1]
			if unit_defs.defs[wanted] == nil then
				context:log({ type = "error", value = `There is no def "{wanted}"` })
				return
			elseif campaign.is_lockable(wanted) == false then
				context:log({ type = "info", value = `{wanted} is never locked: nothing builds it` })
				return
			end
			local outcome, why = campaign_session.grant(player, { wanted }, true)
			local kind, line = pow_common.outcome_line(`Unlocked {wanted} for {player.Name}`, outcome, why)
			context:log({ type = kind, value = line })
		end,
	}

	commands.unlock_all = {
		description = "Unlocks everything in the campaign for you, or for the player given, saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: Context)
			local target = pow_builders.target_player(context, 1)
			local names = lockable_defs()
			local outcome, why = campaign_session.grant(target, names, true)
			local kind, line =
				pow_common.outcome_line(`Unlocked all {#names} buildable defs for {target.Name}`, outcome, why)
			context:log({ type = kind, value = line })
		end,
	}

	commands.unlock_reset = {
		description = "Takes you, or the player given, back to the campaign's starting unlocks, the missions finished "
			.. "staying finished, saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: Context)
			local target = pow_builders.target_player(context, 1)
			local outcome, why = campaign_session.relock(target, true)
			local kind, line = pow_common.outcome_line(
				`{target.Name} is back to the starting unlocks: {table.concat(campaign.STARTING_UNLOCKS, ", ")}`,
				outcome,
				why
			)
			context:log({ type = kind, value = line })
		end,
	}

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
