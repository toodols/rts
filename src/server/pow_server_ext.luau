-- This game's pow commands.
--
-- pow calls its extension modules to let them register commands, so this one returns a function
-- rather than the dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local config = require(ReplicatedStorage.Shared.config)

local alliances = require(ServerScriptService.Server.alliances)
local godmode = require(ServerScriptService.Server.godmode)
local nocost = require(ServerScriptService.Server.nocost)
local pause = require(ServerScriptService.Server.pause)
local players = require(ServerScriptService.Server.players)
local profiler = require(ServerScriptService.Server.profiler)
local scavengers = require(ServerScriptService.Server.scavengers)
local spawning = require(ServerScriptService.Server.spawning)
local state = require(ServerScriptService.Server.state)

return function(extras: { commands: { [string]: any } })
	local commands = extras.commands

	commands.godmode = {
		description = "Lets every player command every team. With no argument it toggles.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Enabled", type = "boolean" } } },
		},
		server_run = function(context: any)
			local enabled = if context.args[1] ~= nil then context.args[1] else godmode.is_enabled() == false
			godmode.set(enabled)
			context:log({
				type = "info",
				value = if enabled then "Godmode on: you can command every team" else "Godmode off",
			})
		end,
	}

	commands.nocost = {
		description = "Makes everything build for free and at once, as if it cost nothing. With no argument it toggles.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Enabled", type = "boolean" } } },
		},
		server_run = function(context: any)
			local enabled = if context.args[1] ~= nil then context.args[1] else nocost.is_enabled() == false
			nocost.set(enabled)
			context:log({
				type = "info",
				value = if enabled then "Nocost on: everything builds free and instantly" else "Nocost off",
			})
		end,
	}

	commands.pause = {
		description = "Stops the simulation stepping at all, as if the game's speed were zero. With no argument it toggles.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Paused", type = "boolean" } } },
		},
		server_run = function(context: any)
			local paused = if context.args[1] ~= nil then context.args[1] else pause.is_paused() == false
			pause.set(paused)
			context:log({
				type = "info",
				value = if paused then "Paused" else "Unpaused",
			})
		end,
	}

	commands.profile = {
		description = "Shows where each simulation step's time has gone since the last /profile reset, heaviest first.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			local rows = profiler.report()
			if #rows == 0 then
				context:log({ type = "info", value = "No profiler data yet" })
				return
			end
			local steps = profiler.step_count()
			local elapsed = profiler.elapsed_since_reset()
			local sim_seconds = steps * config.TICK_DELTA
			context:log({
				type = "info",
				value = `{steps} steps over {string.format("%.1f", elapsed)}s wall time ({string.format(
					"%.1f",
					sim_seconds
				)}s of sim time; over 1.0x is falling behind)`,
			})
			for _, row in rows do
				context:log({
					type = "info",
					value = `  {row.label}: {string.format("%.2f", row.ms_per_step)}ms/step, {string.format(
						"%.1f",
						row.fraction * 100
					)}%`,
				})
			end

			-- entity counts, to catch a leak - something that only ever grows and never comes back down
			profiler.sample_entities()
			local summary = profiler.entity_report()
			context:log({
				type = "info",
				value = `entities: {summary.total} ({if summary.total_delta >= 0 then "+" else ""}{summary.total_delta} since reset)`,
			})
			for _, row in summary.by_kind do
				context:log({
					type = "info",
					value = `  {row.label}: {row.count} ({if row.delta >= 0 then "+" else ""}{row.delta})`,
				})
			end
			-- def names past the top few are rarely the thing worth looking at; the kind breakdown
			-- above already says whether it's units, buildings or wrecks piling up
			for index, row in summary.by_def do
				if index > 8 then
					break
				end
				context:log({
					type = "info",
					value = `  {row.label}: {row.count} ({if row.delta >= 0 then "+" else ""}{row.delta})`,
				})
			end
		end,
	}

	commands.profile_reset = {
		description = "Clears the /profile counters and starts a fresh window.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			profiler.reset()
			context:log({ type = "info", value = "Profiler reset" })
		end,
	}

	commands.ally = {
		description = "Allies two teams. It is transitive: their allies become allies of each other too. Allies do not shoot each other.",
		permissions = { "admin" },
		overloads = {
			{
				returns = "nil",
				args = { { name = "Team1", type = "number" }, { name = "Team2", type = "number" } },
			},
		},
		server_run = function(context: any)
			local a = context.args[1]
			local b = context.args[2]
			if state.get_team(a) == nil or state.get_team(b) == nil then
				context:log({ type = "error", value = `There is no team {if state.get_team(a) == nil then a else b}` })
				return
			end
			local joined = alliances.ally(a, b)
			context:log({
				type = "info",
				value = `{if joined then "Allied" else "Already allied"}: teams {table.concat(
					alliances.group_of(a, state.all_teams()),
					", "
				)}`,
			})
		end,
	}

	commands.scavengers = {
		description = "Turns the scavengers gamemode on or off: whether beacons appear and make anything. With no argument it toggles.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Enabled", type = "boolean" } } },
		},
		server_run = function(context: any)
			local enabled = if context.args[1] ~= nil then context.args[1] else scavengers.is_enabled() == false
			scavengers.set_enabled(enabled)
			context:log({
				type = "info",
				value = if enabled then "Scavengers on" else "Scavengers off",
			})
		end,
	}

	commands.list_teams = {
		description = "Lists every team: its number, name, who plays it, its allies and what it has in the bank.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			local teams = state.all_teams()
			local ids = {}
			for id in teams do
				table.insert(ids, id)
			end
			table.sort(ids)
			if #ids == 0 then
				context:log({ type = "info", value = "There are no teams" })
				return
			end

			for _, id in ids do
				local team = teams[id]
				local names = {}
				for _, player in players.players_on_team(id) do
					table.insert(names, player.Name)
				end
				local allies = {}
				for _, ally in alliances.group_of(id, teams) do
					if ally ~= id then
						table.insert(allies, tostring(ally))
					end
				end
				context:log({
					type = "info",
					value = `{id}: "{team.name}" | player: {if #names > 0 then table.concat(names, ", ") else "none"} | allies: {if #allies > 0
						then table.concat(allies, ", ")
						else "none"} | metal {math.floor(team.metal)} / {math.floor(team.metal_capacity)}, energy {math.floor(
						team.energy
					)} / {math.floor(team.energy_capacity)}`,
				})
			end
		end,
	}

	commands.newteam = {
		description = "Makes a new team with the given name and puts a commander down for it, as if a player had joined.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Name", type = "string" } } },
		},
		server_run = function(context: any)
			local team_id = players.create_team(context.args[1])
			local placed = spawning.give_starting_force(team_id)
			context:log({
				type = if placed then "info" else "error",
				value = if placed
					then `Team {team_id} "{context.args[1]}" created`
					else `Team {team_id} "{context.args[1]}" created, but there was no room for its commander`,
			})
		end,
	}

	commands.scavprogress = {
		description = "Sets how far the scavengers' game has got, from 0 to 1. Their difficulty follows it, and it goes on rising from there.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Progress", type = "number" } } },
		},
		server_run = function(context: any)
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
		server_run = function(context: any)
			local progress, budget = scavengers.set_difficulty(context.args[1])
			context:log({
				type = "info",
				value = `Scavenger difficulty {string.format("%.0f", budget)}, progress {string.format("%.3f", progress)}`,
			})
		end,
	}

	commands.beacon = {
		description = "Puts a scavenger beacon down now, at a random place away from the players.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
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
		server_run = function(context: any)
			local placed = scavengers.force_beacon(context.args[1], context.args[2])
			context:log({
				type = if placed then "info" else "error",
				value = if placed then "A beacon has appeared" else "Nowhere to stand there",
			})
		end,
	}
end
