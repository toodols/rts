-- Where each player's equipped skin is kept: a DataStore (STORE), one key a player, holding `{ equipped = <skin name> }`.
--
-- Only a server may use it. It lives in shared so that the lobby place and the game place read and write it the same
-- way, and a skin equipped in one is worn in the other. Nothing here remembers anything between calls.
--
-- A player nobody has stored anything for yet has equipped nothing, which is not a failure (nil, nil). A read that
-- fails, which is how it is in Studio when the place cannot use DataStores, returns nil and why, and whoever asked
-- should then carry on with the default skin and never save over what may be stored.

local DataStoreService = game:GetService "DataStoreService"

local STORE = "skins_v1"
-- A read or a write is tried this many times, this far apart, before it is given up on.
local ATTEMPTS = 3
local RETRY_SECONDS = 1

local function key_of(user_id: number): string
	return `player_{user_id}`
end

-- The store, asked for only when it is used: getting it throws where DataStores cannot be used.
local function get_store(): (DataStore?, string?)
	local ok, result = pcall(DataStoreService.GetDataStore, DataStoreService, STORE)
	if ok == false then
		return nil, tostring(result)
	end
	return result, nil
end

-- The skin `user_id` has equipped, or nil if they never equipped one. The second result is why it could not be read,
-- if it could not. Yields.
local function load(user_id: number): (string?, string?)
	local store, reason = get_store()
	if store == nil then
		return nil, reason
	end
	local last = "not tried"
	for attempt = 1, ATTEMPTS do
		local ok, value = pcall(function(): any
			return (store :: DataStore):GetAsync(key_of(user_id))
		end)
		if ok then
			if typeof(value) == "table" and typeof(value.equipped) == "string" then
				return value.equipped, nil
			end
			return nil, nil
		end
		last = tostring(value)
		if attempt < ATTEMPTS then
			task.wait(RETRY_SECONDS)
		end
	end
	return nil, last
end

-- Stores that `user_id` has equipped the skin called `skin_name`. Returns whether it was stored, and why not. Yields.
local function save(user_id: number, skin_name: string): (boolean, string?)
	local store, reason = get_store()
	if store == nil then
		return false, reason
	end
	local last = "not tried"
	for attempt = 1, ATTEMPTS do
		local ok, result = pcall(function(): any
			return (store :: DataStore):UpdateAsync(key_of(user_id), function(old: any): any
				local stored = if typeof(old) == "table" then table.clone(old) else {}
				stored.equipped = skin_name
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

return table.freeze({
	load = load,
	save = save,
})
