-- Who the game's developers are: they may do what nobody else may, such as give a player a resource bonus in the lobby.
-- The list is a DataStore's, so that it is the same in every place of the experience and can be changed while the game
-- runs, with pow's `developer` command. Besides those listed, the experience's owner always is one, and in Studio
-- everyone is.
--
-- A server reads the list for each player as they join (`load`) and publishes it on them as ATTRIBUTE, which is what
-- `is_developer` reads, on the server or a client. Only a server reads or changes the store.

local DataStoreService = game:GetService "DataStoreService"
local Players = game:GetService "Players"
local RunService = game:GetService "RunService"

local STORE = "developers"
local KEY = "list"
local ATTRIBUTE = "developer"

-- The user ids the store lists, or nil and why if it could not be read.
local function read(): ({ number }?, string?)
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE):GetAsync(KEY)
	end)
	if ok == false then
		return nil, tostring(result)
	end
	local ids: { number } = {}
	if typeof(result) == "table" then
		for _, id in result do
			if typeof(id) == "number" then
				table.insert(ids, id)
			end
		end
	end
	return ids, nil
end

local function is_owner(user_id: number): boolean
	return game.CreatorType == Enum.CreatorType.User and game.CreatorId == user_id
end

local function is_listed(ids: { number }, user_id: number): boolean
	return table.find(ids, user_id) ~= nil
end

local function publish(player: Player, ids: { number })
	player:SetAttribute(ATTRIBUTE, RunService:IsStudio() or is_owner(player.UserId) or is_listed(ids, player.UserId))
end

-- Reads the list and publishes whether `player` is on it. Yields. Someone it cannot be read for is only a developer if
-- they would be without it.
local function load(player: Player)
	local ids = read()
	publish(player, ids or {})
end

local function is_developer(player: Player): boolean
	return player:GetAttribute(ATTRIBUTE) == true
end

-- Adds `user_id` to the list (`listed`) or takes them off it, and publishes it on everyone in this server. Returns the
-- list as it is now, or nil and why it could not be changed. Yields.
local function set(user_id: number, listed: boolean): ({ number }?, string?)
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE):UpdateAsync(KEY, function(old: any)
			local ids: { number } = {}
			if typeof(old) == "table" then
				for _, id in old do
					if typeof(id) == "number" and id ~= user_id then
						table.insert(ids, id)
					end
				end
			end
			if listed then
				table.insert(ids, user_id)
			end
			table.sort(ids)
			return ids
		end)
	end)
	if ok == false then
		return nil, tostring(result)
	end
	local ids = result :: { number }
	for _, player in Players:GetPlayers() do
		publish(player, ids)
	end
	return ids, nil
end

return table.freeze({
	ATTRIBUTE = ATTRIBUTE,
	read = read,
	load = load,
	is_developer = is_developer,
	set = set,
})
