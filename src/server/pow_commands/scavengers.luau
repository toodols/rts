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

	commands.scav_progress = {
		description = "Sets how far the scavengers' game has got, from 0 to 1. Their difficulty follows it, and it goes "
			.. "on rising from there.",
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

	commands.scav_difficulty = {
		description = "Sets the scavengers' difficulty, the number on their readout, by setting the progress that gives "
			.. "it. It goes on rising from there.",
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

	commands.scav_chances = {
		description = "Shows what a scavenger beacon would make of its units and its defences at the current "
			.. "difficulty, and the chance of each. A land beacon's unless Sea is given.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Sea", type = "boolean" } } },
		},
		server_run = function(context: Context)
			local sea = context.args[1] == true
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
			pow_builders.readout(context, lines)
		end,
	}

	commands.scav_beacon = {
		description = "Puts a scavenger beacon down now: at a random place away from the players, or at (X, Z), even "
			.. "next to players, as long as there is ground or water to stand on.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "X", type = "number" }, { name = "Z", type = "number" } } },
		},
		server_run = function(context: Context)
			local x, z = context.args[1], context.args[2]
			local placed = if x ~= nil then scavengers.force_beacon(x, z) else scavengers.summon_beacon()
			context:log({
				type = if placed then "info" else "error",
				value = if placed
					then "A beacon has appeared"
					elseif x ~= nil then "Nowhere to stand there"
					else "There was no room for a beacon",
			})
		end,
	}
end
