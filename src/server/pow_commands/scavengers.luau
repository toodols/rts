-- The pow commands that move the scavengers' game along, say what their beacons would make, and put beacons down.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local pow_types = require(ReplicatedStorage.Shared.pow_types)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local scavengers = require(ServerScriptService.Server.scavengers)

type Context = pow_builders.Context

return function(extras: pow_types.Extras)
	local commands = extras.commands

	commands.scavprogress = {
		description = "Sets how far the scavengers' game has got, from 0 to 1. Their difficulty follows it, and it goes on rising from there.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Progress", type = "number" } } },
		},
		server_run = function(context: Context)
			local progress = scavengers.set_progress(context.args[1])
			context:log({
				type = "info",
				value = `Scavenger progress {string.format("%.3f", progress)}, difficulty {string.format(
					"%.0f",
					scavengers.budget()
				)}`,
			})
		end,
	}

	commands.scavdifficulty = {
		description = "Sets the scavengers' difficulty, the number on their readout, by setting the progress that gives it. It goes on rising from there.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Difficulty", type = "number" } } },
		},
		server_run = function(context: Context)
			local progress, budget = scavengers.set_difficulty(context.args[1])
			context:log({
				type = "info",
				value = `Scavenger difficulty {string.format("%.0f", budget)}, progress {string.format(
					"%.3f",
					progress
				)}`,
			})
		end,
	}

	commands.scavchances = {
		description = "Shows what a scavenger beacon would make of its units and its defences at the current "
			.. "difficulty, and the chance of each. A land beacon's unless Sea is given.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Sea", type = "boolean" } } },
		},
		server_run = function(context: Context)
			local sea = context.args[1] == true
			-- one log call, as /profile does, so the whole table copies in one go
			local lines = {
				`{if sea then "Sea" else "Land"} beacon at difficulty {string.format("%.0f", scavengers.budget())}`,
			}
			for _, defense in { false, true } do
				local chances = scavengers.spawn_chances(defense, sea)
				table.insert(lines, `{if defense then "Defences" else "Units"} ({#chances}):`)
				if #chances == 0 then
					table.insert(lines, "  none")
				end
				for _, entry in chances do
					table.insert(
						lines,
						`  {string.format("%5.1f", entry.chance * 100)}%  {entry.def_name} (difficulty {string.format(
							"%.1f",
							entry.difficulty
						)})`
					)
				end
			end
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.beacon = {
		description = "Puts a scavenger beacon down now, at a random place away from the players.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			local placed = scavengers.summon_beacon()
			context:log({
				type = if placed then "info" else "error",
				value = if placed then "A beacon has appeared" else "There was no room for a beacon",
			})
		end,
	}

	commands.force_beacon = {
		description = "Puts a scavenger beacon down at (X, Z) right now, even next to players, for testing. "
			.. "It still needs valid ground or water to stand on.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "X", type = "number" }, { name = "Z", type = "number" } } },
		},
		server_run = function(context: Context)
			local placed = scavengers.force_beacon(context.args[1], context.args[2])
			context:log({
				type = if placed then "info" else "error",
				value = if placed then "A beacon has appeared" else "Nowhere to stand there",
			})
		end,
	}
end
