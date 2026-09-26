-- The pow commands that replace the map, or play a campaign mission on it, and change its wind and tide.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local campaign = require(ReplicatedStorage.Shared.campaign)
local environment = require(ReplicatedStorage.Shared.environment)
local pow_types = require(ReplicatedStorage.Shared.pow_types)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local maps = require(ServerScriptService.Server.maps)
local wind = require(ServerScriptService.Server.wind)

type Context = pow_builders.Context

return function(extras: pow_types.Extras)
	local commands = extras.commands

	commands.map_load = {
		description = "Replaces the map: clears everything off it, resets every team's stockpile and gives each "
			.. "player a new commander at their start. The seed is kept unless one is given. No campaign mission is "
			.. "played on it.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Map", type = "map" } } },
			{ returns = "nil", args = { { name = "Map", type = "map" }, { name = "Seed", type = "number" } } },
		},
		server_run = function(context: Context)
			local name = context.args[1]
			local ok, err = maps.load({ preset = name, seed = context.args[2] })
			context:log({
				type = if ok then "info" else "error",
				value = if ok then `Loaded {name}` else `Could not load {name}: {err}`,
			})
		end,
	}

	commands.mission_load = {
		description = "Plays a campaign mission here, as though it had been started from the campaign screen: loads "
			.. "its map, puts down what it starts with, and gives each player a new commander at its start. Whatever "
			.. "was being played is cleared off, and a game that has ended starts again. Hard plays its hard mode.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Mission", type = "mission" } } },
			{ returns = "nil", args = { { name = "Mission", type = "mission" }, { name = "Hard", type = "boolean" } } },
		},
		server_run = function(context: Context)
			local id = context.args[1]
			local hard = context.args[2] == true
			local ok, err = maps.load({ mission = id, hard = hard })
			local mission = campaign.get(id)
			context:log({
				type = if ok then "info" else "error",
				value = if ok and mission ~= nil
					then `Loaded {mission.label}{if hard then " (Hard)" else ""}`
					else `Could not load {id}: {err}`,
			})
		end,
	}

	commands.map_wind = {
		description = "Sets the least and most the wind blows until the next map is loaded, which sets its own. "
			.. "With no arguments it says what they are.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Least", type = "number" }, { name = "Most", type = "number" } } },
		},
		server_run = function(context: Context)
			if context.args[1] ~= nil then
				local ok, reason = environment.set_wind(context.args[1], context.args[2])
				if ok == false then
					context:log({ type = "error", value = reason })
					return
				end
				wind.refit()
			end
			context:log({
				type = "info",
				value = `Wind {environment.min_wind()} to {environment.max_wind()}, blowing {string.format(
					"%.1f",
					wind.speed()
				)}`,
			})
		end,
	}

	commands.map_tidal = {
		description = "Sets the tidal strength, the energy a tidal generator makes a second, until the next map is "
			.. "loaded, which sets its own. With no argument it says what it is.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Strength", type = "number" } } },
		},
		server_run = function(context: Context)
			if context.args[1] ~= nil then
				local ok, reason = environment.set_tidal(context.args[1])
				if ok == false then
					context:log({ type = "error", value = reason })
					return
				end
			end
			context:log({ type = "info", value = `Tidal strength {environment.tidal_strength()}` })
		end,
	}
end
