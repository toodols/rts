-- The pow commands that say how the game stands and how it is set up, and how its simulation is doing.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local tick_rate = require(ReplicatedStorage.Shared.tick_rate)
local environment = require(ReplicatedStorage.Shared.environment)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local map_state = require(ReplicatedStorage.Shared.map_state)
local pow_types = require(ReplicatedStorage.Shared.pow_types)
local switches = require(ReplicatedStorage.Shared.switches)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local benchmark = require(ServerScriptService.Server.benchmark)
local match = require(ServerScriptService.Server.match)
local missions = require(ServerScriptService.Server.missions)
local profiler = require(ServerScriptService.Server.profiler)
local scavengers = require(ServerScriptService.Server.scavengers)
local state = require(ServerScriptService.Server.state)
local warp = require(ServerScriptService.Server.warp)
local wind = require(ServerScriptService.Server.wind)

local team_readout = require(script.Parent.team_readout)

type Context = pow_builders.Context

local list_or = pow_builders.list_or
local one_decimal = team_readout.one_decimal

-- The switches that are on (shared/switches.luau), the scavengers with their difficulty, and whether it is warping.
local function switches_on(): { string }
	local on: { string } = {}
	for _, name in switches.active() do
		table.insert(
			on,
			if name == "scavengers"
				then `scavengers (difficulty {string.format("%.0f", scavengers.budget())})`
				else name
		)
	end
	if warp.is_warping() then
		table.insert(on, "warping")
	end
	return on
end

return function(extras: pow_types.Extras)
	local commands = extras.commands

	commands.profile = {
		description = "Shows where each simulation step's time has gone since the last profile_reset, heaviest first, "
			.. "and how many entities there are of each kind.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			local rows = profiler.report()
			if #rows == 0 then
				context:log({ type = "info", value = "No profiler data yet" })
				return
			end
			local steps = profiler.step_count()
			local elapsed = profiler.elapsed_since_reset()
			local sim_seconds = steps * tick_rate.TICK_DELTA

			-- one log call, everything newline-joined into it: pow prints a call as a single
			-- message, which is what makes the result copyable in one go
			local lines = {
				`{steps} steps over {string.format("%.1f", elapsed)}s wall time ({string.format("%.1f", sim_seconds)}s of sim time; over 1.0x is falling behind)`,
			}
			for _, row in rows do
				table.insert(
					lines,
					`  {row.label}: {string.format("%.2f", row.ms_per_step)}ms/step, {string.format(
						"%.1f",
						row.fraction * 100
					)}%`
				)
			end

			-- entity counts, to catch a leak - something that only ever grows and never comes back down
			local summary = profiler.entity_report()
			table.insert(
				lines,
				`entities: {summary.total} ({if summary.total_delta >= 0 then "+" else ""}{summary.total_delta} since reset)`
			)
			for _, row in summary.by_kind do
				table.insert(lines, `  {row.label}: {row.count} ({if row.delta >= 0 then "+" else ""}{row.delta})`)
			end
			-- def names past the top few are rarely the thing worth looking at; the kind breakdown
			-- above already says whether it's units, buildings or wrecks piling up
			for index, row in summary.by_def do
				if index > 8 then
					break
				end
				table.insert(lines, `  {row.label}: {row.count} ({if row.delta >= 0 then "+" else ""}{row.delta})`)
			end

			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.profile_reset = {
		description = "Clears the profile counters and starts a fresh window.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			profiler.reset()
			context:log({ type = "info", value = "Profiler reset" })
		end,
	}

	commands.benchmark = {
		description = "Runs a fixed set of performance scenarios one after another in a corner of the map "
			.. "(idle units, melee combat, ranged combat, mass movement, production, construction, "
			.. "reclaim/resurrect, transport, and a mixed late-game slice of all of it at once), each "
			.. "timed by the profiler, and prints the whole report as text to paste elsewhere once it "
			.. "is done. Blocks until the run finishes, which takes a couple of minutes.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			benchmark.run(function(line: string)
				context:log({ type = "info", value = line })
			end)
		end,
	}

	commands.game_status = {
		description = "Shows the state of this game: its phase, map and seed, the mission being played, how many "
			.. "players, teams and entities there are, and which debug switches (godmode, nocost, pause, warp, "
			.. "scavengers) are on.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			local map = map_state.get()
			local team_count = 0
			for _ in state.all_teams() do
				team_count += 1
			end
			local by_kind: { [string]: number } = {}
			local entity_count = 0
			for _, entity in state.all() do
				entity_count += 1
				by_kind[entity.kind] = (by_kind[entity.kind] or 0) + 1
			end
			local kinds: { string } = {}
			for kind, count in by_kind do
				table.insert(kinds, `{kind} {count}`)
			end
			table.sort(kinds)
			local winners: { string } = {}
			for _, id in game_phase.winners() do
				table.insert(winners, tostring(id))
			end
			local on = switches_on()
			local phase = game_phase.phase()
			local lines = {
				`phase: {phase}{if phase == "ended" then " | winners: " .. list_or(winners, "none") else ""}`,
				`map: {if map ~= nil then map.preset else "none"} | seed: {if map ~= nil
					then tostring(map.seed)
					else "-"}` .. ` | mission: {missions.mission() or "none"}`,
				`{#Players:GetPlayers()} players, {team_count} teams, {entity_count} entities ({list_or(kinds, "none")})`,
				`wind {one_decimal(wind.speed())} ({environment.min_wind()} to {environment.max_wind()}),`
					.. ` tidal {environment.tidal_strength()}`,
				`on: {list_or(on, "nothing")}`,
			}
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.game_config = {
		description = "Shows how this game is set up: the match (mode, ally griefing, how it ends), the scavengers' "
			.. "progress, difficulty, pace, health multiplier and spawn rate, and the simulation's rate. The map, "
			.. "seed and switches are game_status's.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			local current = match.get()
			local mode = if current ~= nil then game_modes.get(current.mode) else nil
			local scav = scavengers.status()
			local rate = scavengers.SETTINGS.SPAWN_RATE
			local lines = {
				`match: {if mode ~= nil then mode.label else "none"}`
					.. ` | ally griefing: {if current ~= nil and current.ally_griefing then "on" else "off"}`
					.. ` | ends: {if current ~= nil then current.end_mode else "-"}`,
				`scavengers: {if scav.enabled then "on" else "off"} | progress {string.format("%.3f", scav.progress)}`
					.. ` (spawning from {scavengers.SETTINGS.SPAWN_PROGRESS}) | difficulty {string.format(
						"%.0f",
						scav.budget
					)} | boss: {if scav.boss then "out" else "not yet"}`,
				`  pace x{one_decimal(scav.pace)} ({math.floor(scav.game_length)} s to full progress) | health`
					.. ` x{one_decimal(scav.health_multiplier)}`,
				`  spawn rate x{one_decimal(rate)}: units every {one_decimal(scavengers.SETTINGS.SPAWN_INTERVAL / rate)} s, defences every {one_decimal(
					scavengers.SETTINGS.DEFENSE_SPAWN_INTERVAL / rate
				)} s` .. ` (sea x{scavengers.SETTINGS.SEA_SPAWN_MULTIPLIER} slower)`,
				`  beacons {scav.beacons}/{scavengers.SETTINGS.MAX_BEACONS}{if scav.next_beacon_in ~= nil
					then ` (next in {math.floor(scav.next_beacon_in)} s)`
					else ""} | units {scav.units}/{scavengers.SETTINGS.UNIT_CEILING} | reroll credit`
					.. ` {math.floor(scavengers.reroll_credit())}`,
				`sim: {tick_rate.TICK_RATE} ticks/s | rate x{one_decimal(game_phase.sim_rate())}`,
			}
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}
end
