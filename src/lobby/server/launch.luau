-- Starting a lobby's game: a server of the game place is reserved for it, the match is left in the MemoryStore under
-- that server's PrivateServerId for the game to read (see server/match.luau in the game), and everyone in the lobby is
-- teleported there together.

local MemoryStoreService = game:GetService "MemoryStoreService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local TeleportService = game:GetService "TeleportService"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local places = require(ReplicatedStorage.Shared.places)

type Match = game_modes.Match

-- Starts `match` for `players`. Yields until they are on their way, or returns why they could not be sent.
local function start(match: Match, players: { Player }): (boolean, string?)
	if RunService:IsStudio() then
		return false, "Games can't be started from Studio: teleports only work in a live server"
	end
	if places.GAME == 0 then
		return false, "The game place isn't set up yet"
	end

	local reserved, code, server_id = pcall(function()
		return TeleportService:ReserveServer(places.GAME)
	end)
	if reserved == false then
		warn(`reserving a game server failed: {code}`)
		return false, "Couldn't reserve a game server"
	end

	local stored, store_err = pcall(function()
		MemoryStoreService:GetHashMap(game_modes.MATCH_STORE)
			:SetAsync(server_id, game_modes.encode(match), game_modes.MATCH_TTL)
	end)
	if stored == false then
		warn(`storing the match failed: {store_err}`)
		return false, "Couldn't hand the match to its server"
	end

	local options = Instance.new "TeleportOptions"
	options.ReservedServerAccessCode = code
	local sent, send_err = pcall(function()
		TeleportService:TeleportAsync(places.GAME, players, options)
	end)
	if sent == false then
		warn(`teleporting to the game failed: {send_err}`)
		return false, "Couldn't send everyone to the game"
	end
	return true, nil
end

-- Sends `player` to the lobby `lobby_id` on the lobby server `job_id`, where they are seated as they arrive.
local function go_to_lobby(player: Player, job_id: string, lobby_id: string): (boolean, string?)
	if RunService:IsStudio() then
		return false, "Lobbies on other servers can't be joined from Studio"
	end
	local options = Instance.new "TeleportOptions"
	options.ServerInstanceId = job_id
	options:SetTeleportData({ join = lobby_id })
	local sent, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if sent == false then
		warn(`teleporting to lobby {job_id}/{lobby_id} failed: {err}`)
		return false, "Couldn't get to that lobby's server"
	end
	return true, nil
end

return table.freeze({
	start = start,
	go_to_lobby = go_to_lobby,
})
