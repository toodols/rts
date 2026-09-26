--!strict
-- The developers' list (see shared/developers.luau): a record of its own in a DataStore, so that it is the same in every
-- place of the experience and can be changed while the game runs, with pow's `developer` command. Besides those listed,
-- the experience's owner always is one, and in Studio everyone is.
--
-- A server reads the list for each player as they join (`joined`, a lifecycle stage of its own, lifecycle.luau) and
-- publishes whether they are on it on them (developers.publish); what has to know first waits for that
-- (`wait_published`). Changing the list (`set`) publishes it again on everyone in the server.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"
local RunService = game:GetService "RunService"

local developers = require(ReplicatedStorage.Shared.developers)
local signal = require(ReplicatedStorage.Shared.signal)

local record_store = require(script.Parent.record_store)

local KEY = "list"

-- the user ids listed, sorted
local store = record_store.new({
	store = "developers",
	decode = function(value: any): { number }
		local ids: { number } = {}
		if typeof(value) == "table" then
			for _, id in value do
				if typeof(id) == "number" then
					table.insert(ids, id)
				end
			end
		end
		table.sort(ids)
		return ids
	end,
	encode = function(ids: { number }): any
		return ids
	end,
})

-- told of each player whose being a developer was published, as it was
local published = signal.new() :: signal.Signal<Player>
-- each player here whose being a developer is still being read, with the threads waiting for it
local reading: { [Player]: { thread } } = {}

-- The experience's owner, who is always a developer.
local function is_owner(user_id: number): boolean
	return game.CreatorType == Enum.CreatorType.User and game.CreatorId == user_id
end

local function publish(player: Player, ids: { number })
	developers.publish(
		player,
		RunService:IsStudio() or is_owner(player.UserId) or table.find(ids, player.UserId) ~= nil
	)
	published.fire(player)
end

-- The user ids listed, or nil and why if the list could not be read. Yields.
local function read(): ({ number }?, string?)
	return store.load(KEY)
end

-- Reads the list for `player`, who has just joined, and publishes whether they are on it, without holding anything up.
-- Someone it cannot be read for is only a developer if they would be without it.
local function joined(player: Player)
	local waiting: { thread } = {}
	reading[player] = waiting
	task.spawn(function()
		local ids = read() or {}
		if reading[player] ~= waiting then
			-- they left while it was being read
			return
		end
		reading[player] = nil
		publish(player, ids)
		for _, thread in waiting do
			task.spawn(thread)
		end
	end)
end

-- Yields until whether `player` is a developer has been published, as it is as they join.
local function wait_published(player: Player)
	local waiting = reading[player]
	if waiting ~= nil then
		table.insert(waiting, coroutine.running())
		coroutine.yield()
	end
end

-- `player` has left: whoever waits on them stops waiting.
local function left(player: Player)
	local waiting = reading[player]
	reading[player] = nil
	if waiting ~= nil then
		for _, thread in waiting do
			task.spawn(thread)
		end
	end
end

-- Adds `user_id` to the list (`listed`) or takes them off it, and publishes it on everyone in this server. Returns the
-- list as it is now, or nil and why it could not be changed. Yields.
local function set(user_id: number, listed: boolean): ({ number }?, string?)
	local ids, problem = store.update(KEY, function(old: { number }): { number }
		local changed: { number } = {}
		for _, id in old do
			if id ~= user_id then
				table.insert(changed, id)
			end
		end
		if listed then
			table.insert(changed, user_id)
		end
		table.sort(changed)
		return changed
	end)
	if ids == nil then
		return nil, problem
	end
	for _, player in Players:GetPlayers() do
		publish(player, ids)
	end
	return ids, nil
end

-- Tells `listener` of each player whose being a developer is published, as it is, until the returned function is
-- called.
local function on_published(listener: (Player) -> ()): () -> ()
	return published.subscribe(listener)
end

return table.freeze({
	is_owner = is_owner,
	read = read,
	joined = joined,
	wait_published = wait_published,
	left = left,
	set = set,
	on_published = on_published,
})
