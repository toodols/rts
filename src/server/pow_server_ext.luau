-- This game's pow commands.
--
-- pow calls its extension modules to let them register commands, so this one returns a function
-- rather than the dictionary RULES.md asks of every other module.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"
local Workspace = game:GetService "Workspace"

local config = require(ReplicatedStorage.Shared.config)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local environment = require(ReplicatedStorage.Shared.environment)
local shared_skins = require(ReplicatedStorage.Shared.skins)
local campaign_defs = require(ReplicatedStorage.Shared.campaign)
local developers = require(ReplicatedStorage.Shared.developers)
local game_modes = require(ReplicatedStorage.Shared.game_modes)
local game_phase = require(ReplicatedStorage.Shared.game_phase)
local map_state = require(ReplicatedStorage.Shared.map_state)
local starts = require(ReplicatedStorage.Shared.starts)
local ai_profiles = require(ReplicatedStorage.Shared.ai_profiles)

local ai = require(ServerScriptService.Server.ai)
local alliances = require(ServerScriptService.Server.alliances)
local benchmark = require(ServerScriptService.Server.benchmark)
local campaign = require(ServerScriptService.Server.campaign)
local economy = require(ServerScriptService.Server.economy)
local match_stats = require(ServerScriptService.Server.match_stats)
local godmode = require(ServerScriptService.Server.godmode)
local lobby = require(ServerScriptService.Server.lobby)
local maps = require(ServerScriptService.Server.maps)
local match = require(ServerScriptService.Server.match)
local missions = require(ServerScriptService.Server.missions)
local nocost = require(ServerScriptService.Server.nocost)
local pause = require(ServerScriptService.Server.pause)
local players = require(ServerScriptService.Server.players)
local possession = require(ServerScriptService.Server.possession)
local profiler = require(ServerScriptService.Server.profiler)
local scavengers = require(ServerScriptService.Server.scavengers)
local skins = require(ServerScriptService.Server.skins)
local spawning = require(ServerScriptService.Server.spawning)
local state = require(ServerScriptService.Server.state)
local warp = require(ServerScriptService.Server.warp)
local wind = require(ServerScriptService.Server.wind)

-- What every campaign mission is called, for a command told of one there is not.
local function mission_ids(): string
	local ids = {}
	for _, mission in campaign_defs.MISSIONS do
		table.insert(ids, mission.id)
	end
	return table.concat(ids, ", ")
end

local function one_decimal(value: number): string
	return string.format("%.1f", value)
end

local function list_or(names: { string }, empty: string): string
	return if #names > 0 then table.concat(names, ", ") else empty
end

-- Every def that can be locked in the campaign.
local function lockable_defs(): { string }
	local names: { string } = {}
	for name in unit_defs.defs do
		if campaign_defs.is_lockable(name) then
			table.insert(names, name)
		end
	end
	return names
end

-- Every def that can be locked in the campaign, split by whether `unlocks` has it, each sorted.
local function split_unlocks(unlocks: { [string]: boolean }): ({ string }, { string })
	local unlocked: { string } = {}
	local locked: { string } = {}
	for name in unit_defs.defs do
		if campaign_defs.is_lockable(name) then
			table.insert(if unlocks[name] == true then unlocked else locked, name)
		end
	end
	table.sort(unlocked)
	table.sort(locked)
	return unlocked, locked
end

-- A multi-line readout of team `team_id`: who plays it, its bank and flow, what it has on the map and what it has done
-- this game. Nil for a team there is not.
local function describe_team(team_id: number): { string }?
	local team = state.get_team(team_id)
	if team == nil then
		return nil
	end
	local names: { string } = {}
	for _, player in players.players_on_team(team_id) do
		table.insert(names, player.Name)
	end
	local allies: { string } = {}
	for _, ally in alliances.group_of(team_id, state.all_teams()) do
		if ally ~= team_id then
			table.insert(allies, tostring(ally))
		end
	end

	local units, buildings, blueprints = 0, 0, 0
	local by_def: { [string]: number } = {}
	local commander_health: string? = nil
	for _, entity in state.all() do
		if entity.team ~= team_id or (entity.kind ~= "unit" and entity.kind ~= "building") then
			continue
		end
		if entity.state == "blueprint" then
			blueprints += 1
			continue
		end
		if entity.kind == "unit" then
			units += 1
		else
			buildings += 1
		end
		by_def[entity.def_name] = (by_def[entity.def_name] or 0) + 1
		if entity.def_name == "commander" then
			commander_health = `{math.floor(entity.health)} / {math.floor(entity.max_health)}`
		end
	end
	local counts: { { name: string, count: number } } = {}
	for name, count in by_def do
		table.insert(counts, { name = name, count = count })
	end
	table.sort(counts, function(a, b)
		return if a.count ~= b.count then a.count > b.count else a.name < b.name
	end)
	local top: { string } = {}
	for index, row in counts do
		if index > 10 then
			table.insert(top, `+{#counts - 10} more kinds`)
			break
		end
		table.insert(top, `{row.name} x{row.count}`)
	end

	local tally = match_stats.tally_for(team_id)
	local unlocks = campaign.unlocks_of_team(team_id)
	local may_build = "anything (no player on it)"
	if unlocks ~= nil then
		may_build = `{#(split_unlocks(unlocks))} lockable defs unlocked`
	end
	local bonus = economy.bonus_of(team_id)
	local notes = ""
	if bonus ~= 0 then
		notes ..= ` | bonus {one_decimal(bonus)}%`
	end
	if table.find(ai.teams(), team_id) ~= nil then
		notes ..= " | played by the AI"
	end
	return {
		`Team {team_id} "{team.name}" | players: {list_or(names, "none")} | allies: {list_or(allies, "none")}`
			.. ` | skin: {team.skin}{notes}`,
		`  metal {math.floor(team.metal)} / {math.floor(team.metal_capacity)}, income {one_decimal(team.metal_income)}/s`
			.. ` (in {one_decimal(team.metal_revenue)}, out {one_decimal(team.metal_expense)})`,
		`  energy {math.floor(team.energy)} / {math.floor(team.energy_capacity)}, income {one_decimal(
			team.energy_income
		)}/s` .. ` (in {one_decimal(team.energy_revenue)}, out {one_decimal(team.energy_expense)})`,
		`  {units} units, {buildings} buildings, {blueprints} blueprints | commander: {commander_health or "none"}`,
		`  most: {list_or(top, "nothing")}`,
		`  this game: {math.floor(tally.damage)} damage (worth {math.floor(tally.destroyed)}), {tally.kills} kills,`
			.. ` {tally.lost} lost, {math.floor(tally.metal)} metal made`,
		`  may build: {may_build}`,
	}
end

return function(extras: { commands: { [string]: any } })
	local commands = extras.commands

	commands.developer = {
		description = "Adds a user to the game's developers, who alone may give lobby players a resource bonus, "
			.. "or takes them off it. The list is the same in every place. With no arguments it says who is on it.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{
				returns = "nil",
				args = { { name = "UserId", type = "number" }, { name = "Developer", type = "boolean" } },
			},
		},
		server_run = function(context: any)
			local user_id, listed = context.args[1], context.args[2]
			local ids, err
			if user_id == nil then
				ids, err = developers.read()
			else
				ids, err = developers.set(user_id, listed)
			end
			if ids == nil then
				context:log({ type = "error", value = `Could not reach the developer list: {err}` })
				return
			end
			local names: { string } = {}
			for _, id in ids do
				table.insert(names, tostring(id))
			end
			context:log({
				type = "info",
				value = if #names > 0
					then `Developers: {table.concat(names, ", ")} (and the game's owner)`
					else "No developers listed (only the game's owner is one)",
			})
		end,
	}

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

	commands.load_map = {
		description = "Replaces the map: clears everything off it, resets every team's stockpile and gives each "
			.. "player a new commander at their start. The seed is kept unless one is given. A campaign mission being "
			.. "played is left.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Map", type = "map" } } },
			{ returns = "nil", args = { { name = "Map", type = "map" }, { name = "Seed", type = "number" } } },
		},
		server_run = function(context: any)
			local name = context.args[1]
			missions.begin(nil)
			local ok, err = maps.load(name, context.args[2])
			context:log({
				type = if ok then "info" else "error",
				value = if ok then `Loaded {name}` else `Could not load {name}: {err}`,
			})
		end,
	}

	commands.load_mission = {
		description = "Plays a campaign mission here, as though it had been started from the campaign screen: loads "
			.. "its map, puts down what it starts with, and gives each player a new commander at its start. Whatever "
			.. "was being played is cleared off, and a game that has ended starts again.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Mission", type = "string" } } },
		},
		server_run = function(context: any)
			local id = context.args[1]
			local mission = campaign_defs.get(id)
			if mission == nil then
				context:log({ type = "error", value = `There is no mission "{id}"; there are {mission_ids()}` })
				return
			end
			local ok, err = maps.load_mission(id)
			context:log({
				type = if ok then "info" else "error",
				value = if ok then `Loaded {mission.label}` else `Could not load {id}: {err}`,
			})
		end,
	}

	commands.wind = {
		description = "Sets the least and most the wind blows until the next map is loaded, which sets its own. "
			.. "With no arguments it says what they are.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Least", type = "number" }, { name = "Most", type = "number" } } },
		},
		server_run = function(context: any)
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

	commands.tidal = {
		description = "Sets the tidal strength, the energy a tidal generator makes a second, until the next map is "
			.. "loaded, which sets its own. With no argument it says what it is.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Strength", type = "number" } } },
		},
		server_run = function(context: any)
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

	commands.warp = {
		description = "Runs the next Ticks ticks of the simulation as fast as it can, every step right after "
			.. "the last with no real-time pacing between them, instead of the usual one tick per (roughly) "
			.. "1/20th of a second, then goes back to normal. Replaces any warp already running; /unwarp "
			.. "stops it early. With no argument it says how many ticks are left.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Ticks", type = "number" } } },
		},
		server_run = function(context: any)
			local ticks = context.args[1]
			if ticks == nil then
				local remaining = warp.ticks_remaining()
				context:log({
					type = "info",
					value = if remaining == 0
						then "Not warping"
						elseif remaining == math.huge then "Warping until stopped"
						else `Warping, {remaining} ticks left`,
				})
				return
			end
			ticks = math.floor(ticks)
			if ticks <= 0 then
				context:log({ type = "error", value = "Ticks must be at least 1" })
				return
			end
			warp.start(ticks)
			context:log({
				type = "info",
				value = `Warping {ticks} ticks ({string.format("%.1f", ticks * config.TICK_DELTA)}s of sim time)`,
			})
		end,
	}

	commands.unwarp = {
		description = "Stops a /warp early, going back to one tick per (roughly) 1/20th of a second.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			if warp.is_warping() == false then
				context:log({ type = "info", value = "Not warping" })
				return
			end
			local remaining = warp.ticks_remaining()
			warp.stop()
			context:log({
				type = "info",
				value = if remaining == math.huge then "Warp stopped" else `Warp stopped with {remaining} ticks left`,
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
			profiler.sample_entities()
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

	commands.unally = {
		description = "Takes a team out of whatever alliance it is in. The teams it leaves stay allied with each other.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Team", type = "number" } } },
		},
		server_run = function(context: any)
			local team_id = context.args[1]
			if state.get_team(team_id) == nil then
				context:log({ type = "error", value = `There is no team {team_id}` })
				return
			end
			local former = alliances.group_of(team_id, state.all_teams())
			if alliances.leave(team_id) == false then
				context:log({ type = "info", value = `Team {team_id} is allied with nobody` })
				return
			end
			table.remove(former, table.find(former, team_id) :: number)
			context:log({
				type = "info",
				value = `Team {team_id} is allied with nobody; teams {table.concat(former, ", ")} are still allied`,
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

	commands.skin = {
		description = "Puts a team in a skin, and everything it has with it: your own team, or the one given. "
			.. "Every skin is open to this command, the developer-only golden one too. It lasts until someone on the "
			.. "team equips a skin, and is not saved: to change what a player wears for good, use equip. With no "
			.. "arguments it says which skin your team wears and which there are.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Skin", type = "skin" } } },
			{ returns = "nil", args = { { name = "Skin", type = "skin" }, { name = "Team", type = "number" } } },
		},
		server_run = function(context: any)
			local team_id = if context.args[2] ~= nil then context.args[2] else players.team_of(context.executor)
			if team_id == nil then
				context:log({ type = "error", value = "You are not on a team; give one" })
				return
			end
			local skin_name = context.args[1]
			if skin_name == nil then
				context:log({
					type = "info",
					value = `Team {team_id} wears {skins.of_team(team_id) or "nothing"}; the skins are {table.concat(
						shared_skins.names(),
						", "
					)}`,
				})
				return
			end
			local ok = skins.set_team(team_id, skin_name)
			context:log({
				type = if ok then "info" else "error",
				value = if ok then `Team {team_id} now wears {skin_name}` else `There is no team {team_id}`,
			})
		end,
	}

	commands.skins = {
		description = "Lists every skin: whether only developers may wear it, what it changes, who has it equipped, "
			.. "and which teams wear it.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			for _, name in shared_skins.names() do
				local skin = shared_skins.get(name)
				local notes = {}
				if skin.developer_only then
					table.insert(notes, "developers only")
				end
				local stats = skin.stats
				if stats ~= nil then
					table.insert(
						notes,
						`health x{stats.health or 1}, range x{stats.range or 1}, damage x{stats.damage or 1}`
					)
				end
				if skin.paint ~= nil then
					table.insert(notes, "repainted")
				end
				if skin.art ~= nil then
					table.insert(notes, "other art")
				end
				for _, attachment in skin.attachments do
					table.insert(notes, `wears a {attachment.kind}`)
				end
				local wearers = {}
				for _, player in Players:GetPlayers() do
					if skins.equipped_by(player) == name then
						table.insert(wearers, player.Name)
					end
				end
				local teams = {}
				for id, team in state.all_teams() do
					if team.skin == name then
						table.insert(teams, tostring(id))
					end
				end
				table.sort(teams)
				context:log({
					type = "info",
					value = `{name} ({skin.display_name}){if #notes > 0 then ": " .. table.concat(notes, "; ") else ""}`
						.. ` | equipped by: {if #wearers > 0 then table.concat(wearers, ", ") else "nobody"}`
						.. ` | teams: {if #teams > 0 then table.concat(teams, ", ") else "none"}`,
				})
			end
		end,
	}

	commands.equip = {
		description = "Equips a skin for you, or for the player given, as the HUD's skins picker does: it goes on "
			.. "their team and everything it has, and is saved for next time. Unlike the picker it may equip anything, "
			.. "golden too. With no arguments it says what you have equipped.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Skin", type = "skin" } } },
			{ returns = "nil", args = { { name = "Skin", type = "skin" }, { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[2] ~= nil then context.args[2] else context.executor
			local skin_name = context.args[1]
			if skin_name == nil then
				context:log({ type = "info", value = `{target.Name} has {skins.equipped_by(target)} equipped` })
				return
			end
			local ok, reason = skins.equip(target, skin_name, true)
			context:log({
				type = if ok then "info" else "error",
				value = if ok then `{target.Name} now has {skin_name} equipped` else `Could not equip it: {reason}`,
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
					value = `{id}: "{team.name}" | player: {if #names > 0 then table.concat(names, ", ") else "none"} | allies: {if #allies
							> 0
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

	commands.team_join = {
		description = "Puts you, or the player given, on a team, to share it with whoever is on it: they command "
			.. "everything it has and spend from one bank. The team they leave keeps what it has. Before the game "
			.. "starts they take the team's start; once it is playing, a team with nothing yet gets a commander.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Team", type = "number" } } },
			{ returns = "nil", args = { { name = "Player", type = "player" }, { name = "Team", type = "number" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[2] ~= nil then context.args[1] else context.executor
			local team_id: number = if context.args[2] ~= nil then context.args[2] else context.args[1]
			-- the neutral team and the scavengers are nobody's to play
			if team_id == 0 or team_id == config.SCAVENGER_TEAM or state.get_team(team_id) == nil then
				context:log({ type = "error", value = `There is no team {team_id} to join` })
				return
			end
			if players.team_of(target) == team_id then
				context:log({ type = "info", value = `{target.Name} is already on team {team_id}` })
				return
			end
			possession.release_player(target)
			target:SetAttribute("spectator", nil)
			players.move(target, team_id)
			lobby.team_changed(target)
			local team = state.get_team(team_id) :: any
			context:log({ type = "info", value = `{target.Name} is on team {team_id} "{team.name}"` })
		end,
	}

	commands.team_split = {
		description = "Takes you, or the player given, off a shared team onto a new one of their own. The team they "
			.. "leave keeps what it has; once the game is playing, the new team gets a commander.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[1] ~= nil then context.args[1] else context.executor
			possession.release_player(target)
			target:SetAttribute("spectator", nil)
			local team_id = players.split(target)
			skins.set_team(team_id, skins.equipped_by(target))
			lobby.team_changed(target)
			context:log({ type = "info", value = `{target.Name} is on a team of their own, team {team_id}` })
		end,
	}

	-- ai_add's arguments come in this order, each overload taking one more: where it starts is either a start box
	-- (Start, 0 for the free start furthest from everyone) or a spot (X, Z), and the two are told apart by what comes
	-- fourth, a number only for a spot.
	local AI_NAME = { name = "Name", type = "string" }
	local AI_COUNT = { name = "Count", type = "number" }
	local AI_START = { name = "Start", type = "number" }
	local AI_X = { name = "X", type = "number" }
	local AI_Z = { name = "Z", type = "number" }
	local AI_SIDE = { name = "Side", type = "ai_side" }
	local AI_TEAM = { name = "Team", type = "number" }
	local AI_LINE = { name = "Line", type = "ai_line" }
	local AI_PROFILE = { name = "Profile", type = "ai_profile" }

	commands.ai_add = {
		description = "Adds AI players, by default one enemy at the free start furthest from everyone. Start: a box, 0 "
			.. "for the furthest. Side: enemy, ally (of Team) or join (plays Team). Line: bot, vehicle or any. "
			.. "Profile: how it plays (default, raider, swarm, turtle).",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { AI_NAME } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_START } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_X, AI_Z } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_START, AI_SIDE, AI_TEAM } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_X, AI_Z, AI_SIDE, AI_TEAM } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_START, AI_SIDE, AI_TEAM, AI_LINE } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_X, AI_Z, AI_SIDE, AI_TEAM, AI_LINE } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_START, AI_SIDE, AI_TEAM, AI_LINE, AI_PROFILE } },
			{ returns = "nil", args = { AI_NAME, AI_COUNT, AI_X, AI_Z, AI_SIDE, AI_TEAM, AI_LINE, AI_PROFILE } },
		},
		server_run = function(context: any)
			local args = context.args
			local name: string? = args[1]
			local count: number = if args[2] ~= nil then math.floor(args[2]) else 1
			local at: Vector2? = nil
			local box: number? = nil
			local next_arg = 4
			if typeof(args[4]) == "number" then
				if heightmap.in_bounds(args[3], args[4]) == false then
					context:log({ type = "error", value = `({args[3]}, {args[4]}) is off the map` })
					return
				end
				at = Vector2.new(args[3], args[4])
				next_arg = 5
			elseif args[3] ~= nil and args[3] ~= 0 then
				box = math.floor(args[3])
				if box < 1 or box > starts.box_count() then
					context:log({
						type = "error",
						value = `There is no start {box}; there are 1 to {starts.box_count()}`,
					})
					return
				end
			end
			local side: string = args[next_arg] or "enemy"
			local team: number = args[next_arg + 1] or 0
			local line: string? = args[next_arg + 2]
			-- "any" leaves the line to the profile, or to the AI
			if line == "any" then
				line = nil
			end
			local profile_name: string = args[next_arg + 3] or "default"
			local profile = ai_profiles.get(profile_name)
			if profile == nil then
				context:log({ type = "error", value = `There is no AI profile {profile_name}` })
				return
			end

			if count < 1 then
				context:log({ type = "error", value = "Count must be at least 1" })
				return
			end
			if side ~= "enemy" and (team == 0 or team == config.SCAVENGER_TEAM or state.get_team(team) == nil) then
				context:log({ type = "error", value = `There is no team {team} to {side}` })
				return
			end

			-- Where the next commander goes, worked out afresh for each so that each keeps clear of the last, or why
			-- there is nowhere.
			local function start(): (Vector2?, string?)
				if at ~= nil then
					return at, nil
				elseif box ~= nil then
					local spot = ai.box_start(box)
					return spot,
						if spot == nil
							then `Start {box} has no ground left {ai.MIN_START_SPACING} studs from everyone`
							else nil
				end
				local spot = ai.free_start()
				return spot,
					if spot == nil
						then `Nowhere on the map is {ai.MIN_START_SPACING} studs from everyone; give a start or X Z`
						else nil
			end

			-- joining plays a team that is already there, so there is only ever the one
			if side == "join" then
				local team_id = team
				local spot: Vector2? = nil
				if spawning.owns_anything(team_id) == false then
					local reason
					spot, reason = start()
					if spot == nil then
						context:log({ type = "error", value = reason })
						return
					end
				end
				local placed = ai.take_over(team_id, spot, profile)
				if placed and line ~= nil then
					ai.set_line(team_id, line :: any)
				end
				context:log({
					type = if placed then "info" else "error",
					value = if placed
						then `Team {team_id} is played by the AI`
						else "There was no room for the AI's commander",
				})
				return
			end

			-- every AI is put down before anything is said, so that a log that fails cannot leave the rest undone
			local lines: { string } = {}
			local failed = false
			for index = 1, count do
				local spot, reason = start()
				if spot == nil then
					table.insert(lines, reason :: string)
					failed = true
					break
				end
				local team_name = if name ~= nil and count > 1 then `{name} {index}` else name
				local team_id = ai.spawn_opponent(team_name, spot, if side == "ally" then team else nil, profile)
				if team_id == nil then
					table.insert(lines, "There was no room for the AI's commander")
					failed = true
					break
				end
				if line ~= nil then
					ai.set_line(team_id, line :: any)
				end
				table.insert(
					lines,
					if side == "ally"
						then `Team {team_id} is played by the AI, allied with team {team}`
						else `Team {team_id} is played by the AI`
				)
			end
			context:log({ type = if failed then "error" else "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.ai_control = {
		description = "Hands a team to the AI, or takes it back. Without Enabled it flips whether the AI plays it.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Team", type = "number" } } },
			{ returns = "nil", args = { { name = "Team", type = "number" }, { name = "Enabled", type = "boolean" } } },
		},
		server_run = function(context: any)
			local team_id = context.args[1]
			-- the neutral team 0 has nothing for the AI to play
			if team_id == 0 or state.get_team(team_id) == nil then
				context:log({ type = "error", value = `There is no team {team_id}` })
				return
			end
			local enabled = context.args[2]
			if enabled == nil then
				enabled = not ai.is_ai(team_id)
			end
			if enabled then
				ai.add(team_id)
			else
				ai.remove(team_id)
			end
			context:log({
				type = "info",
				value = if enabled then `Team {team_id} is played by the AI` else `The AI lets team {team_id} go`,
			})
		end,
	}

	commands.ai_profile = {
		description = "Makes the AI playing Team play by Profile from now on (default, raider, swarm, turtle).",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Team", type = "number" }, AI_PROFILE } },
		},
		server_run = function(context: any)
			local team_id = context.args[1]
			local profile = ai_profiles.get(context.args[2])
			if profile == nil then
				context:log({ type = "error", value = `There is no AI profile {context.args[2]}` })
				return
			end
			if ai.set_profile(team_id, profile) == false then
				context:log({ type = "error", value = `The AI does not play team {team_id}` })
				return
			end
			context:log({ type = "info", value = `Team {team_id}'s AI plays as {profile.name}` })
		end,
	}

	commands.ai_status = {
		description = "Says how each team the AI plays is getting on.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			local teams = ai.teams()
			if #teams == 0 then
				context:log({ type = "info", value = "The AI plays no team" })
			end
			for _, team_id in teams do
				context:log({ type = "info", value = ai.describe(team_id) or `Team {team_id}` })
			end
		end,
	}

	commands.give = {
		description = "Spawns a finished unit or building for a team at (X, Z) right now, for testing. It still needs room to stand.",
		permissions = { "admin" },
		overloads = {
			{
				returns = "nil",
				args = {
					{ name = "DefName", type = "unit" },
					{ name = "Team", type = "number" },
					{ name = "X", type = "number" },
					{ name = "Z", type = "number" },
				},
			},
		},
		server_run = function(context: any)
			local def_name = context.args[1]
			local team_id = context.args[2]
			local x = context.args[3]
			local z = context.args[4]

			if unit_defs.defs[def_name] == nil then
				context:log({ type = "error", value = `There is no def "{def_name}"` })
				return
			end
			if state.get_team(team_id) == nil then
				context:log({ type = "error", value = `There is no team {team_id}` })
				return
			end
			if heightmap.in_bounds(x, z) == false then
				context:log({ type = "error", value = `({x}, {z}) is off the map` })
				return
			end

			local entity = spawning.spawn_near(def_name, team_id, heightmap.ground_position(x, z), 0)
			context:log({
				type = if entity ~= nil then "info" else "error",
				value = if entity ~= nil
					then `Gave team {team_id} a {def_name} at ({x}, {z})`
					else `No room for a {def_name} near ({x}, {z})`,
			})
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
		server_run = function(context: any)
			benchmark.run(function(line: string)
				context:log({ type = "info", value = line })
			end)
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
		server_run = function(context: any)
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

	-- The campaign's unlocks (see server/campaign.luau). `unlock` and `relock` last for the session and are not saved;
	-- `complete_mission` is what finishing a mission does, and is saved.
	commands.unlock = {
		description = "Unlocks a def for you in the campaign, or everything with `all`, for this session only: it is "
			.. "not saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "DefName", type = "unit" } } },
		},
		server_run = function(context: any)
			local player = context.executor :: Player
			local wanted = context.args[1]
			local names: { string } = {}
			if wanted == "all" then
				names = lockable_defs()
			elseif unit_defs.defs[wanted] == nil then
				context:log({ type = "error", value = `There is no def "{wanted}"` })
				return
			elseif campaign_defs.is_lockable(wanted) == false then
				context:log({ type = "info", value = `{wanted} is never locked: nothing builds it` })
				return
			else
				table.insert(names, wanted)
			end
			campaign.grant(player, names, false)
			context:log({
				type = "info",
				value = if wanted == "all" then `Unlocked all {#names} buildable defs` else `Unlocked {wanted}`,
			})
		end,
	}

	commands.unlock_all = {
		description = "Unlocks everything in the campaign for you, or for the player given, for this session only: it "
			.. "is not saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[1] ~= nil then context.args[1] else context.executor
			local names = lockable_defs()
			campaign.grant(target, names, false)
			context:log({ type = "info", value = `Unlocked all {#names} buildable defs for {target.Name}` })
		end,
	}

	commands.relock = {
		description = "Takes you back to the campaign's starting unlocks, for this session only: it is not saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			campaign.relock(context.executor :: Player, false)
			context:log({
				type = "info",
				value = `Back to the starting unlocks: {table.concat(campaign_defs.STARTING_UNLOCKS, ", ")}`,
			})
		end,
	}

	commands.reset_data = {
		description = "Wipes what is saved for you, or for the player given, as though they had never played: no "
			.. "missions done, the starting unlocks, and the default skin. That is saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[1] ~= nil then context.args[1] else context.executor
			campaign.reset(target)
			skins.equip(target, config.DEFAULT_SKIN, true)
			local _, saved = campaign.status(target)
			context:log({
				type = "info",
				value = if saved
					then `Reset {target.Name}'s saved data`
					else `Reset {target.Name}'s data for this session; it was never read from the store, so nothing was saved`,
			})
		end,
	}

	commands.complete_mission = {
		description = "Finishes a campaign mission for you, as winning it would: it is marked done and what it unlocks "
			.. "is yours, and that is saved.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Mission", type = "string" } } },
		},
		server_run = function(context: any)
			local id = context.args[1]
			local done = campaign.complete(context.executor :: Player, id)
			if done == false then
				context:log({ type = "error", value = `There is no mission "{id}"; there are {mission_ids()}` })
				return
			end
			context:log({ type = "info", value = `Completed {id}` })
		end,
	}

	-- Read-only readouts, for debugging. Each logs once, everything newline-joined, as /profile does, so it copies in
	-- one go.
	commands.unlocks = {
		description = "Shows your campaign progress, or the player given's: each mission and whether it is done, what "
			.. "it unlocks, every def they have unlocked and every one still locked, and whether their progress was "
			.. "read from the store (and so is saved).",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[1] ~= nil then context.args[1] else context.executor
			local progress, saved = campaign.status(target)
			local unlocked, locked = split_unlocks(progress.unlocks)
			local lines = {
				`{target.Name}'s campaign ({if saved then "read from the store, saved" else "not read, never saved"}):`,
			}
			for _, mission in campaign_defs.MISSIONS do
				table.insert(
					lines,
					`  [{if progress.completed[mission.id] then "x" else " "}] {mission.label} ({mission.id})`
						.. ` unlocks: {list_or(mission.unlocks, "nothing")}`
				)
			end
			table.insert(lines, `Unlocked ({#unlocked}): {list_or(unlocked, "nothing")}`)
			table.insert(lines, `Locked ({#locked}): {list_or(locked, "nothing")}`)
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.player_stats = {
		description = "Shows everything about you, or the player given: user id, developer or not, skin, campaign "
			.. "progress, and their team's bank, income, forces and what it has done this game.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Player", type = "player" } } },
		},
		server_run = function(context: any)
			local target: Player = if context.args[1] ~= nil then context.args[1] else context.executor
			local progress, saved = campaign.status(target)
			local done = 0
			for _, mission in campaign_defs.MISSIONS do
				if progress.completed[mission.id] then
					done += 1
				end
			end
			local unlocked = split_unlocks(progress.unlocks)
			local team_id = players.team_of(target)
			local lines = {
				`{target.Name} ({target.DisplayName}) | user id {target.UserId}`
					.. ` | developer: {if developers.is_developer(target) then "yes" else "no"}`
					.. ` | skin equipped: {skins.equipped_by(target)}`,
				`  campaign: {done} / {#campaign_defs.MISSIONS} missions done, {#unlocked} lockable defs unlocked`
					.. ` ({if saved then "saved" else "not saved"}; /unlocks for the list)`,
			}
			local team_lines = if team_id ~= nil then describe_team(team_id) else nil
			if team_lines == nil then
				table.insert(lines, "  not on a team")
			else
				for _, line in team_lines do
					table.insert(lines, line)
				end
			end
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.team_stats = {
		description = "Shows a team's bank, income, forces and what it has done this game: your own team, or the one "
			.. "given.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
			{ returns = "nil", args = { { name = "Team", type = "number" } } },
		},
		server_run = function(context: any)
			local team_id = if context.args[1] ~= nil then context.args[1] else players.team_of(context.executor)
			if team_id == nil then
				context:log({ type = "error", value = "You are not on a team; give one" })
				return
			end
			local lines = describe_team(team_id)
			if lines == nil then
				context:log({ type = "error", value = `There is no team {team_id}` })
				return
			end
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.match_stats = {
		description = "Shows what every team has done so far this game, as the end screen will: damage dealt and what "
			.. "it was worth, kills, losses and metal made.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			local ids: { number } = {}
			for id in state.all_teams() do
				if id ~= 0 then
					table.insert(ids, id)
				end
			end
			table.sort(ids)
			if #ids == 0 then
				context:log({ type = "info", value = "There are no teams" })
				return
			end
			local lines = { "team: damage (worth) | kills | lost | metal made" }
			for _, id in ids do
				local tally = match_stats.tally_for(id)
				local team = state.get_team(id) :: any
				table.insert(
					lines,
					`  {id} "{team.name}": {math.floor(tally.damage)} ({math.floor(tally.destroyed)}) | {tally.kills}`
						.. ` | {tally.lost} | {math.floor(tally.metal)}`
				)
			end
			context:log({ type = "info", value = table.concat(lines, "\n") })
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
		server_run = function(context: any)
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
			local switches: { string } = {}
			if godmode.is_enabled() then
				table.insert(switches, "godmode")
			end
			if nocost.is_enabled() then
				table.insert(switches, "nocost")
			end
			if pause.is_paused() then
				table.insert(switches, "paused")
			end
			if warp.is_warping() then
				table.insert(switches, "warping")
			end
			if scavengers.is_enabled() then
				table.insert(switches, `scavengers (difficulty {string.format("%.0f", scavengers.budget())})`)
			end
			local phase = game_phase.phase()
			local lines = {
				`phase: {phase}{if phase == "ended" then " | winners: " .. list_or(winners, "none") else ""}`,
				`map: {if map ~= nil then map.preset else "none"} | seed: {if map ~= nil
					then tostring(map.seed)
					else "-"}` .. ` | mission: {campaign_defs.current_mission() or "none"}`,
				`{#Players:GetPlayers()} players, {team_count} teams, {entity_count} entities ({list_or(kinds, "none")})`,
				`wind {one_decimal(wind.speed())} ({environment.min_wind()} to {environment.max_wind()}),`
					.. ` tidal {environment.tidal_strength()}`,
				`on: {list_or(switches, "nothing")}`,
			}
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}

	commands.gameconfig = {
		description = "Shows how this game is set up: the match (mode, map, seed, ally griefing), the scavengers' "
			.. "progress, difficulty, pace, health multiplier and spawn rate, and the simulation's rate and switches.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: any)
			local current = match.get()
			local mode = if current ~= nil then game_modes.get(current.mode) else nil
			local map = map_state.get()
			local scav = scavengers.settings()
			local rate = config.SCAVENGER_SPAWN_RATE
			local switches: { string } = {}
			if godmode.is_enabled() then
				table.insert(switches, "godmode")
			end
			if nocost.is_enabled() then
				table.insert(switches, "nocost")
			end
			if pause.is_paused() then
				table.insert(switches, "paused")
			end
			if warp.is_warping() then
				table.insert(switches, "warping")
			end
			local lines = {
				`match: {if mode ~= nil then mode.label else "none"} | map: {if map ~= nil then map.preset else "none"} | seed: {if map
						~= nil
					then tostring(map.seed)
					else "-"}`
					.. ` | ally griefing: {if current ~= nil and current.ally_griefing then "on" else "off"}`
					.. ` | ends: {if current ~= nil then current.end_mode else "-"}`,
				`scavengers: {if scav.enabled then "on" else "off"} | progress {string.format("%.3f", scav.progress)}`
					.. ` (spawning from {config.SCAVENGER_SPAWN_PROGRESS}) | difficulty {string.format(
						"%.0f",
						scav.budget
					)} | boss: {if scav.boss then "out" else "not yet"}`,
				`  pace x{one_decimal(scav.pace)} ({math.floor(scav.game_length)} s to full progress) | health`
					.. ` x{one_decimal(scav.health_multiplier)}`,
				`  spawn rate x{one_decimal(rate)}: units every {one_decimal(config.SCAVENGER_SPAWN_INTERVAL / rate)} s, defences every {one_decimal(
					config.SCAVENGER_DEFENSE_SPAWN_INTERVAL / rate
				)} s` .. ` (sea x{config.SCAVENGER_SEA_SPAWN_MULTIPLIER} slower)`,
				`  beacons {scav.beacons}/{config.SCAVENGER_MAX_BEACONS}{if scav.next_beacon_in ~= nil
					then ` (next in {math.floor(scav.next_beacon_in)} s)`
					else ""} | units {scav.units}/{config.SCAVENGER_UNIT_CEILING} | reroll credit`
					.. ` {math.floor(scavengers.pending_reroll())}`,
				`sim: {config.TICK_RATE} ticks/s | rate x{one_decimal(Workspace:GetAttribute "sim_rate" or 1)}`
					.. ` | on: {list_or(switches, "nothing")}`,
			}
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}
end
