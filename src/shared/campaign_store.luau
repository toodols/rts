-- Where each player's campaign progress is kept: a DataStore (campaign.PROGRESS_STORE), one key a player
-- (campaign.progress_key), holding what `campaign.Progress` holds as plain tables, sets as { [name] = true }.
--
-- Only a server may use it. It lives in shared so that the lobby place, which shows the campaign, and the game place,
-- which plays it, read and write it the same way. Nothing here remembers anything between calls.
--
-- A player nobody has stored anything for yet is a new player (`campaign.new_progress`), which is not a failure. A read
-- that fails, which is how it is in Studio when the place cannot use DataStores, returns nil and why, and whoever asked
-- should then play on with the starting unlocks and never save over what may be stored.

local DataStoreService = game:GetService "DataStoreService"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)

type Progress = campaign.Progress

-- A read or a write is tried this many times, this far apart, before it is given up on.
local ATTEMPTS = 3
local RETRY_SECONDS = 1

-- The store, asked for only when it is used: getting it throws where DataStores cannot be used.
local function get_store(): (DataStore?, string?)
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, campaign.PROGRESS_STORE)
	if ok == false then
		return nil, tostring(result)
	end
	return result, nil
end

-- `progress` as it is stored: plain tables of names to true.
local function encode(progress: Progress): { [string]: any }
	local completed: { [string]: boolean } = {}
	for id, done in progress.completed do
		if done then
			completed[id] = true
		end
	end
	local unlocks: { [string]: boolean } = {}
	for name, unlocked in progress.unlocks do
		if unlocked then
			unlocks[name] = true
		end
	end
	return { completed = completed, unlocks = unlocks }
end

-- The progress stored for `user_id`, a new player's if nothing is, or nil and why if it could not be read. Yields.
local function load(user_id: number): (Progress?, string?)
	local store, reason = get_store()
	if store == nil then
		return nil, reason
	end
	local last = "not tried"
	for attempt = 1, ATTEMPTS do
		local ok, value = pcall(function(): any
			return (store :: DataStore):GetAsync(campaign.progress_key(user_id))
		end)
		if ok then
			return campaign.decode_progress(value), nil
		end
		last = tostring(value)
		if attempt < ATTEMPTS then
			task.wait(RETRY_SECONDS)
		end
	end
	return nil, last
end

-- Stores `progress` for `user_id`, over whatever was there. Returns whether it was stored, and why not. Yields.
local function save(user_id: number, progress: Progress): (boolean, string?)
	local store, reason = get_store()
	if store == nil then
		return false, reason
	end
	local stored = encode(progress)
	local last = "not tried"
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(function(): any
			return (store :: DataStore):UpdateAsync(campaign.progress_key(user_id), function(_old: any): any
				return stored
			end)
		end)
		if ok then
			return true, nil
		end
		last = tostring(result)
		if attempt < ATTEMPTS then
			task.wait(RETRY_SECONDS)
		end
	end
	return false, last
end

-- Tells `player`, and anything that reads it from them, what they have unlocked (campaign.UNLOCKS_ATTRIBUTE).
local function publish(player: Player, progress: Progress)
	player:SetAttribute(campaign.UNLOCKS_ATTRIBUTE, campaign.encode_unlocks(progress.unlocks))
end

return table.freeze({
	load = load,
	save = save,
	publish = publish,
})
