--!strict
-- Starting a lobby's game, or a campaign mission played alone, on a game server of its own (server_shared/reserved_match.luau):
-- everyone in the lobby (or the one player) goes there together; and sending a player to a lobby on another lobby
-- server. Nothing here knows about lobbies: it is handed a match and the players to send, or where to send one.
--
-- A player whose teleport fails on the way, every time it is tried (server_shared/teleports.luau), is handed to
-- `init`'s callback.

local ReplicatedStorage = game:GetService "ReplicatedStorage"
local ServerScriptService = game:GetService "ServerScriptService"

local game_modes = require(ReplicatedStorage.Shared.game_modes)

local reserved_match = require(ServerScriptService.ServerShared.reserved_match)
local teleports = require(ServerScriptService.ServerShared.teleports)

type Match = game_modes.Match

local on_given_up: teleports.GivenUp? = nil

local function given_up(player: Player, reason: string)
	if on_given_up ~= nil then
		on_given_up(player, reason)
	end
end

-- Starts `match` for `players`. Yields until they are on their way, or returns why they could not be sent.
local function start(match: Match, players: { Player }): (boolean, string?)
	return reserved_match.start(match, players, given_up)
end

-- Sends `player` to the lobby `lobby_id` on the lobby server `job_id`, where they are seated as they arrive.
local function go_to_lobby(player: Player, job_id: string, lobby_id: string): (boolean, string?)
	local options = Instance.new "TeleportOptions"
	options.ServerInstanceId = job_id
	options:SetTeleportData({ join = lobby_id })
	local sent, reason = teleports.send({ player }, game.PlaceId, options, given_up)
	if sent == false then
		warn(`teleporting to lobby {job_id}/{lobby_id} failed: {reason}`)
		return false, teleports.refusal(game.PlaceId) or "Couldn't get to that lobby's server"
	end
	return true, nil
end

-- `given` is told of a player whose teleport failed every time it was tried.
local function init(given: teleports.GivenUp)
	on_given_up = given
end

return table.freeze({
	init = init,
	start = start,
	go_to_lobby = go_to_lobby,
})
