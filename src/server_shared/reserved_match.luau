--!strict
-- Starting a match on a game server of its own, from the lobby, for a lobby's game or a campaign mission played alone
-- (lobby/server/launch.luau); and the reserved server reading it (`receive`, the game's server/match_sources.luau).
--
-- A server of the game place is reserved for it and the players are teleported there together, as one party into
-- that one server (teleports.luau). The match goes with them twice: left in the MemoryStore under the reserved server's
-- PrivateServerId, which is read first because only a server can write it, and so it can be trusted; and as each
-- player's teleport data, which is read only when the store cannot be, from the first of them to arrive. That comes by
-- way of the player's client, so it is only taken from a player one of the experience's places sent who is seated in
-- it, and it is a fallback: it is what would let a client change the map it is sent to.

local MemoryStoreService = game:GetService "MemoryStoreService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local TeleportService = game:GetService "TeleportService"

local game_modes = require(ReplicatedStorage.Shared.game_modes)
local places = require(ReplicatedStorage.Shared.places)

local teleports = require(script.Parent.teleports)

type Match = game_modes.Match

-- The match is written before anyone is sent, but a read can still fail, so it is tried a few times.
local READ_ATTEMPTS = 5
local READ_RETRY_SECONDS = 1

-- Starts `match` for `players`. Yields until they are on their way, or returns why they could not be sent. A player
-- whose teleport fails on the way after that, every time it is tried, is handed to `given_up`.
local function start(match: Match, players: { Player }, given_up: teleports.GivenUp): (boolean, string?)
	local refused = teleports.refusal(places.GAME)
	if refused ~= nil then
		return false, refused
	end

	local reserved, code, server_id = pcall(function()
		return TeleportService:ReserveServer(places.GAME)
	end)
	if reserved == false then
		warn(`reserving a game server failed: {code}`)
		return false, "Couldn't reserve a game server"
	end

	-- the teleport data carries the match too, so a failure here is not the end of it
	local encoded = game_modes.encode(match)
	local stored, store_err = pcall(function()
		MemoryStoreService:GetHashMap(game_modes.MATCH_STORE):SetAsync(server_id, encoded, game_modes.MATCH_TTL)
	end)
	if stored == false then
		warn(`storing the match failed, so the game will read it from the teleport data: {store_err}`)
	end

	local options = Instance.new "TeleportOptions"
	options.ReservedServerAccessCode = code
	options:SetTeleportData({ match = encoded })
	local sent = teleports.send(players, places.GAME, options, given_up)
	if sent == false then
		return false, "Couldn't send everyone to the game"
	end
	return true, nil
end

-- The match `player`'s teleport data holds, if one of the experience's places sent them and they are seated in it.
local function match_from(player: Player): Match?
	local join = player:GetJoinData()
	if join.SourcePlaceId ~= places.LOBBY and join.SourcePlaceId ~= places.GAME then
		return nil
	end
	local data = join.TeleportData
	if typeof(data) ~= "table" then
		return nil
	end
	local found = game_modes.decode((data :: any).match)
	if found == nil then
		return nil
	end
	for _, seat in found.seats do
		if seat.user_id == player.UserId then
			return found
		end
	end
	return nil
end

-- Whether this is a server a lobby reserved.
local function is_reserved(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

-- The match left in the store for this server, if it can be read.
local function read_store(): Match?
	local got, store = pcall(MemoryStoreService.GetHashMap, MemoryStoreService, game_modes.MATCH_STORE)
	if got == false then
		warn(`there is no match store here: {store}`)
		return nil
	end
	for attempt = 1, READ_ATTEMPTS do
		local ok, value = pcall(function(): any
			return store:GetAsync(game.PrivateServerId)
		end)
		if ok and value ~= nil then
			return game_modes.decode(value)
		end
		if ok == false then
			warn(`reading the match failed (attempt {attempt}): {value}`)
		end
		task.wait(READ_RETRY_SECONDS)
	end
	return nil
end

-- The match this server was reserved for, if it was reserved for one and it can be found: from the store, or else from
-- the teleport data of the first player to arrive (`first_player` waits for them). Yields while it reads.
local function receive(first_player: () -> Player?): Match?
	if is_reserved() == false then
		return nil
	end
	local found = read_store()
	if found ~= nil then
		return found
	end
	warn "no match was left in the store for this reserved server; reading it from the teleport data"
	local first = first_player()
	found = if first ~= nil then match_from(first) else nil
	if found == nil then
		warn "this is a reserved server, but no match came with it; playing the usual game"
	end
	return found
end

return table.freeze({
	start = start,
	receive = receive,
})
