-- The pow commands about teams: who is on which, who is allied with whom, what each has and has done, what it wears,
-- and a finished thing given to one.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local heightmap = require(ReplicatedStorage.Shared.heightmap)
local pow_types = require(ReplicatedStorage.Shared.pow_types)
local skin_defs = require(ReplicatedStorage.Shared.skins)
local teams = require(ReplicatedStorage.Shared.teams)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local alliances = require(ServerScriptService.Server.alliances)
local match_stats = require(ServerScriptService.Server.match_stats)
local players = require(ServerScriptService.Server.players)
local skins = require(ServerScriptService.Server.skins)
local spawning = require(ServerScriptService.Server.spawning)
local state = require(ServerScriptService.Server.state)
local team_moves = require(ServerScriptService.Server.team_moves)

local team_readout = require(script.Parent.team_readout)

type Context = pow_builders.Context

local target_player = pow_builders.target_player
local readout = pow_builders.readout

-- The team argument `index` of `context` names, or the team of whoever ran the command, if they are on one.
local function target_team(context: Context, index: number): number?
	local given = context.args[index]
	return if given ~= nil then given else players.team_of(context.executor)
end

-- Every team's id, in order.
local function team_ids(): { number }
	local ids: { number } = {}
	for id in state.all_teams() do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

return function(extras: pow_types.Extras)
	local commands = extras.commands

	commands.ally = {
		description = "Allies two teams. It is transitive: their allies become allies of each other too. Allies do "
			.. "not shoot each other.",
		permissions = { "admin" },
		overloads = {
			{
				returns = "nil",
				args = { { name = "Team1", type = "number" }, { name = "Team2", type = "number" } },
			},
		},
		server_run = function(context: Context)
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
		server_run = function(context: Context)
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

	commands.list_teams = {
		description = "Lists every team: its number, name, who plays it, its allies and what it has in the bank.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			local lines: { string } = {}
			for _, id in team_ids() do
				table.insert(lines, team_readout.summary(id) :: string)
			end
			readout(context, if #lines > 0 then lines else { "There are no teams" })
		end,
	}

	commands.team_stats = {
		description = "Shows a team's bank, income, forces and what it has done this game: your own team, or the one "
			.. "given.",
		permissions = { "admin" },
		overloads = pow_types.TEAM_OR_YOURS,
		server_run = function(context: Context)
			local team_id = target_team(context, 1)
			if team_id == nil then
				context:log({ type = "error", value = "You are not on a team; give one" })
				return
			end
			local lines = team_readout.full(team_id)
			if lines == nil then
				context:log({ type = "error", value = `There is no team {team_id}` })
				return
			end
			readout(context, lines)
		end,
	}

	commands.match_stats = {
		description = "Shows what every team has done so far this game, as the end screen will: damage dealt and what "
			.. "it was worth, kills, losses and metal made.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			local lines = { "team: damage (worth) | kills | lost | metal made" }
			for _, id in team_ids() do
				if id == teams.NEUTRAL then
					continue
				end
				local tally = match_stats.tally_for(id)
				local team = state.get_team(id) :: any
				table.insert(
					lines,
					`  {id} "{team.name}": {math.floor(tally.damage)} ({math.floor(tally.destroyed)}) | {tally.kills}`
						.. ` | {tally.lost} | {math.floor(tally.metal)}`
				)
			end
			readout(context, lines)
		end,
	}

	commands.newteam = {
		description = "Makes a new team with the given name and puts a commander down for it, as if a player had joined.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = { { name = "Name", type = "string" } } },
		},
		server_run = function(context: Context)
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
		server_run = function(context: Context)
			local joining = context.args[2] ~= nil
			local target: Player = if joining then context.args[1] else context.executor
			local team_id: number = if joining then context.args[2] else context.args[1]
			local ok, why = team_moves.join(target, team_id)
			local team = state.get_team(team_id)
			context:log({
				type = if ok then "info" else "error",
				value = if ok and team ~= nil then `{target.Name} is on team {team_id} "{team.name}"` else why,
			})
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
		server_run = function(context: Context)
			local target = target_player(context, 1)
			local team_id = team_moves.split(target)
			context:log({ type = "info", value = `{target.Name} is on a team of their own, team {team_id}` })
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
		server_run = function(context: Context)
			local team_id = target_team(context, 2)
			if team_id == nil then
				context:log({ type = "error", value = "You are not on a team; give one" })
				return
			end
			local skin_name = context.args[1]
			if skin_name == nil then
				context:log({
					type = "info",
					value = `Team {team_id} wears {skins.of_team(team_id) or "nothing"}; the skins are {table.concat(
						skin_defs.names(),
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

	commands.give = {
		description = "Spawns a finished unit or building for a team at (X, Z) right now, for testing. It still needs "
			.. "room to stand.",
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
		server_run = function(context: Context)
			local def_name, team_id, x, z = context.args[1], context.args[2], context.args[3], context.args[4]
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
end
