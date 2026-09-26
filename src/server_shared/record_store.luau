--!strict
-- A DataStore of records, as every place of the experience keeps them: a player's equipped skin, their campaign
-- progress, their ratings, the developers' list. Every store is declared here, in STORES, with the one convention they
-- all keep to, and each record is read and written through the same `decode` and `encode`, so every place reads what
-- another wrote the same way.
--
-- - A store's name is its record's name and version (`<name>_v<version>`); a record whose shape changes so that the
--   old cannot be read as the new goes to a new version, which starts empty.
-- - A player's record is kept under `player_<user id>` (`player_key`); a store of one record, under its name.
--
-- The developers' list and the ratings were stored before the convention, under names and keys of their own, which are
-- kept as they are (LEGACY_NAMES, and ratings' `user_` key, `legacy_player_key`), since renaming a store is losing what
-- is in it.
--
-- Nothing is read or written in Studio (`enabled`): a Studio session plays with a new player's records, the way a test
-- expects to, and the live data is never touched from it. A read or a write that fails is tried again a few times
-- before it is given up on; one that is given up on, or refused because stores are off, says why, and whoever asked
-- should then carry on without it and never save over what may be stored. A change is applied inside the store's own
-- update (`update`), to what is stored at that moment, so that what another server wrote meanwhile is kept, not
-- overwritten.
--
-- Only a server can use a DataStore, which is why this lives where only servers can see it.

local DataStoreService = game:GetService "DataStoreService"
local RunService = game:GetService "RunService"

-- Every store the experience keeps, and its version.
export type StoreName = "skins" | "campaign_progress" | "ratings" | "developers"

local STORES: { [StoreName]: number } = table.freeze({
	skins = 1,
	campaign_progress = 1,
	ratings = 1,
	developers = 1,
})

-- The stores named before the convention, by the name they are kept under.
local LEGACY_NAMES: { [StoreName]: string } = table.freeze({
	ratings = "ratings",
	developers = "developers",
})

export type Spec<T> = {
	store: StoreName,
	-- the record a stored value holds; what a key that has nothing stored under it holds as well (from nil)
	decode: (any) -> T,
	encode: (T) -> any,
}

export type Store<T> = {
	-- The record stored under `key`, or nil and why it could not be read. Yields.
	load: (key: string) -> (T?, string?),
	-- Stores `change` of what is stored under `key`, and returns the record as it now is, or nil and why it could not
	-- be. Yields.
	update: (key: string, change: (T) -> T) -> (T?, string?),
}

-- A read or a write is tried this many times, this far apart, before it is given up on.
local ATTEMPTS = 3
local RETRY_SECONDS = 1
local DISABLED = "records are neither read nor written in Studio"

-- Whether records are read and written here: on a live server, and never in Studio.
local function enabled(): boolean
	return RunService:IsStudio() == false
end

-- The key a player's record is kept under.
local function player_key(user_id: number): string
	return `player_{user_id}`
end

-- The key a player's ratings are kept under, from before the convention.
local function legacy_player_key(user_id: number): string
	return `user_{user_id}`
end

-- Runs `attempt` until it does not throw, ATTEMPTS times at the most. Returns what it returned, or nil and the last
-- error.
local function with_retries(attempt: () -> any): (any, string?)
	local last = "not tried"
	for index = 1, ATTEMPTS do
		local ok, result = pcall(attempt)
		if ok then
			return result, nil
		end
		last = tostring(result)
		if index < ATTEMPTS then
			task.wait(RETRY_SECONDS)
		end
	end
	return nil, last
end

local function new<T>(spec: Spec<T>): Store<T>
	local name = LEGACY_NAMES[spec.store] or `{spec.store}_v{STORES[spec.store]}`

	-- asked for only when it is used: getting it throws where DataStores cannot be used
	local function get_store(): DataStore
		return DataStoreService:GetDataStore(name)
	end

	local function load(key: string): (T?, string?)
		if enabled() == false then
			return nil, DISABLED
		end
		local value, problem = with_retries(function(): any
			return { stored = get_store():GetAsync(key) }
		end)
		if problem ~= nil then
			return nil, problem
		end
		return spec.decode(value.stored), nil
	end

	local function update(key: string, change: (T) -> T): (T?, string?)
		if enabled() == false then
			return nil, DISABLED
		end
		local changed: T? = nil
		local _, problem = with_retries(function(): any
			return get_store():UpdateAsync(key, function(old: any): any
				changed = change(spec.decode(old))
				return spec.encode(changed :: T)
			end)
		end)
		if problem ~= nil then
			return nil, problem
		end
		return changed, nil
	end

	return table.freeze({
		load = load,
		update = update,
	})
end

return table.freeze({
	enabled = enabled,
	player_key = player_key,
	legacy_player_key = legacy_player_key,
	new = new,
})
