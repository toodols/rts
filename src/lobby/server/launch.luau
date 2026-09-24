-- Starting a lobby's game, or a campaign mission played alone. A server of the game place is reserved for it and
-- everyone in the lobby (or the one player) is teleported there together, as one party into that one server. Nothing
-- here knows about lobbies: it is handed a match and the players to send. The match goes with them twice (see server/match.luau in the game):
-- left in the MemoryStore under the reserved server's PrivateServerId, which the game reads first because only a server
-- can write it, and as each player's teleport data, which it falls back on when the store cannot be read.
--
-- A player whose teleport fails after the party has been sent - Roblox reports it through TeleportInitFailed - is sent
-- again on their own, to the same server with the same data, up to RETRIES times before they are given up on.

local MemoryStoreService = game:GetService "MemoryStoreService"
local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"
local TeleportService = game:GetService "TeleportService"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local places = require(ReplicatedStorage.Shared.places)

type Match = game_modes.Match

type Pending = {
	options: TeleportOptions,
	tries: number,
}

local RETRIES = 3
local RETRY_SECONDS = 2

-- players on their way to a game, with the options they were sent with, until they leave this server
local pending: { [Player]: Pending } = {}
local on_given_up: ((player: Player, reason: string) -> ())? = nil

-- What a player is sent to a game with: the match, as game_modes encodes it.
local function teleport_data(match: Match): { [string]: any }
	return { match = game_modes.encode(match) }
end

-- Starts `match` for `players`. Yields until they are on their way, or returns why they could not be sent. A player
-- whose teleport later fails for good is handed to `init`'s callback.
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

	-- the teleport data carries the match too, so a failure here is not the end of it
	local stored, store_err = pcall(function()
		MemoryStoreService:GetHashMap(game_modes.MATCH_STORE)
			:SetAsync(server_id, game_modes.encode(match), game_modes.MATCH_TTL)
	end)
	if stored == false then
		warn(`storing the match failed, so the game will read it from the teleport data: {store_err}`)
	end

	local options = Instance.new "TeleportOptions"
	options.ReservedServerAccessCode = code
	options:SetTeleportData(teleport_data(match))
	for _, player in players do
		pending[player] = { options = options, tries = 0 }
	end
	local sent, send_err = pcall(function()
		TeleportService:TeleportAsync(places.GAME, players, options)
	end)
	if sent == false then
		for _, player in players do
			pending[player] = nil
		end
		warn(`teleporting to the game failed: {send_err}`)
		return false, "Couldn't send everyone to the game"
	end
	return true, nil
end

local function on_init_failed(player: Player, result: Enum.TeleportResult, message: string)
	local waiting = pending[player]
	if waiting == nil then
		return
	end
	waiting.tries += 1
	warn(`{player.Name}'s teleport to the game failed ({result.Name}, try {waiting.tries}): {message}`)
	if waiting.tries > RETRIES then
		pending[player] = nil
		if on_given_up ~= nil then
			on_given_up(player, message)
		end
		return
	end
	task.wait(RETRY_SECONDS)
	-- they may have got there, or gone, meanwhile
	if pending[player] ~= waiting or player.Parent == nil then
		return
	end
	local sent, err = pcall(function()
		TeleportService:TeleportAsync(places.GAME, { player }, waiting.options)
	end)
	if sent == false then
		on_init_failed(player, Enum.TeleportResult.Failure, tostring(err))
	end
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

-- `given_up` is told of a player whose teleport to their game failed every time it was tried.
local function init(given_up: (player: Player, reason: string) -> ())
	on_given_up = given_up
	TeleportService.TeleportInitFailed:Connect(on_init_failed)
	-- leaving is what a teleport that worked looks like from here
	Players.PlayerRemoving:Connect(function(player: Player)
		pending[player] = nil
	end)
end

return table.freeze({
	init = init,
	start = start,
	go_to_lobby = go_to_lobby,
})
