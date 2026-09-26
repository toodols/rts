--!strict
-- The lobby's pow commands: those every place has (server_shared/pow_common.luau), with what only the lobby knows of a
-- player, the lobby or mission they are in, and a readout of this server's lobbies.
--
-- pow calls its extension modules to let them register commands, so this one returns a function rather than the
-- dictionary RULES.md asks of every other module.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local pow_types = require(ReplicatedStorage.Shared.pow_types)

local pow_common = require(ServerScriptService.ServerShared.pow_common)
local pow_builders = require(ServerScriptService.ServerShared.pow_builders)

local lobbies = require(script.Parent.lobbies)
local mission_starts = require(script.Parent.mission_starts)

type Lobby = lobbies.Lobby
type Context = pow_builders.Context

-- `lobby` in a few lines: its settings, then each seat.
local function describe_lobby(lobby: Lobby): { string }
	local host = Players:GetPlayerByUserId(lobby.host)
	local stage = if lobby.teleporting then "teleporting" elseif lobby.starting then "starting" else "open"
	local ok, blocked = lobbies.can_start(lobby)
	local lines = {
		`{lobby.id}: host {if host ~= nil then host.Name else tostring(lobby.host)} | {lobby.match.mode} on {lobby.match.preset}`
			.. ` (seed {lobby.match.seed}) | {lobby.visibility} | ally griefing {if lobby.match.ally_griefing
				then "on"
				else "off"}`
			.. ` | ends {lobby.match.end_mode} | {stage}{if ok then ", can start" else ` ({blocked})`}`,
	}
	for _, seat in lobby.match.seats do
		local bonus = lobby.match.bonuses[tostring(seat.user_id)]
		table.insert(
			lines,
			`  side {seat.side}: {seat.name} ({seat.user_id})`
				.. `{if lobby.ready[seat.user_id] == true then ", ready" else ""}`
				.. `{if bonus ~= nil then `, bonus {bonus}%` else ""}`
		)
	end
	return lines
end

local LOBBY: pow_common.Place = table.freeze({
	player_lines = function(player: Player): { string }
		local lines: { string } = {}
		local mission = mission_starts.mission_of(player)
		if mission ~= nil then
			local why = if mission.reason ~= nil then ` ({mission.reason})` else ""
			table.insert(lines, `  mission: {mission.id}, {mission.stage}{why}`)
		end
		local lobby = lobbies.of_user(player.UserId)
		if lobby == nil then
			table.insert(lines, "  in no lobby")
		else
			for _, line in describe_lobby(lobby) do
				table.insert(lines, `  {line}`)
			end
		end
		return lines
	end,
})

return function(extras: pow_types.Extras)
	local commands = extras.commands
	pow_common.register(commands, LOBBY)

	commands.lobbies = {
		description = "Lists the lobbies on this server: each one's settings, whether it can start, and who is in it "
			.. "on which side.",
		permissions = { "admin" },
		overloads = {
			{ returns = "nil", args = {} },
		},
		server_run = function(context: Context)
			local ids: { string } = {}
			for id in lobbies.all() do
				table.insert(ids, id)
			end
			table.sort(ids)
			local lines = { `{#ids} lobbies on this server ({#Players:GetPlayers()} players here)` }
			for _, id in ids do
				local lobby = lobbies.get(id)
				if lobby ~= nil then
					for _, line in describe_lobby(lobby) do
						table.insert(lines, line)
					end
				end
			end
			context:log({ type = "info", value = table.concat(lines, "\n") })
		end,
	}
end
