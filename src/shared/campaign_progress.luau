--!strict
-- What a player has done in the campaign (see campaign.luau): the missions they have finished and what they have
-- unlocked, as it is kept, published and changed. Everything here is pure: a change is a function from one progress to
-- the next, so that the same change is applied to what a server holds and, inside the store's own update, to what is
-- stored (server_shared/campaign_session.luau), and nothing another server saved meanwhile is lost.
--
-- It is stored in the campaign_progress store (server_shared/record_store.luau), one key a player, as `{ completed =
-- set, unlocks = set }`, a set being `{ [name] = true }`. A server publishes it on the player (shared/replicated.luau),
-- each a sorted list of names: what they have unlocked, which the build menu and the lobby read (`unlocks_of`), and the
-- missions they have finished (`completed_of`).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local replicated = require(ReplicatedStorage.Shared.replicated)

export type Set = { [string]: boolean }

export type Progress = {
	-- mission ids
	completed: Set,
	-- def names, the starting ones included
	unlocks: Set,
}

local UNLOCKS = replicated.player("campaign", "unlocks", replicated.STRINGS)
local COMPLETED = replicated.player("campaign", "completed", replicated.STRINGS)

-- The set a stored or sent value holds: its string keys that are true, or the names of a list, or, for a comma
-- separated string, its names.
-- Anything else holds nothing.
local function set_of(value: any): Set
	local set: Set = {}
	if typeof(value) == "string" then
		for _, name in string.split(value, ",") do
			if name ~= "" then
				set[name] = true
			end
		end
	elseif typeof(value) == "table" then
		for key, entry in value do
			if typeof(key) == "string" and entry == true then
				set[key] = true
			elseif typeof(key) == "number" and typeof(entry) == "string" then
				set[entry] = true
			end
		end
	end
	return set
end

-- `set` as it is published: the names, sorted.
local function list_of(set: Set): { string }
	local names: { string } = {}
	for name, present in set do
		if present then
			table.insert(names, name)
		end
	end
	table.sort(names)
	return names
end

-- Everything in `a` and everything in `b`.
local function union(a: Set, b: Set): Set
	local set = set_of(a)
	for name in set_of(b) do
		set[name] = true
	end
	return set
end

-- A new player's progress: nothing finished, and the starting unlocks.
local function new(): Progress
	return { completed = {}, unlocks = campaign.starting_unlocks() }
end

-- The progress a value read from the store holds; a new player's for anything that is not one. The starting unlocks
-- are always in it.
local function decode(value: any): Progress
	if typeof(value) ~= "table" then
		return new()
	end
	return { completed = set_of(value.completed), unlocks = union(campaign.starting_unlocks(), set_of(value.unlocks)) }
end

-- `progress` as it is stored.
local function encode(progress: Progress): { [string]: any }
	return { completed = set_of(progress.completed), unlocks = set_of(progress.unlocks) }
end

-- Everything either has finished or unlocked.
local function merge(a: Progress, b: Progress): Progress
	return { completed = union(a.completed, b.completed), unlocks = union(a.unlocks, b.unlocks) }
end

-- `progress` with the mission `mission_id` finished, and its hard mode as well for `hard` if it has one, and what that
-- unlocks unlocked (campaign.unlocks_for); as it was, for a mission there is not.
local function complete(progress: Progress, mission_id: string, hard: boolean): Progress
	local mission = campaign.get(mission_id)
	if mission == nil then
		return progress
	end
	local in_hard = hard and mission.hard_mode
	local finished: Set = { [mission_id] = true }
	if in_hard then
		finished[campaign.key(mission_id, true)] = true
	end
	local unlocks: Set = {}
	for _, name in campaign.unlocks_for(mission, in_hard) do
		unlocks[name] = true
	end
	return { completed = union(progress.completed, finished), unlocks = union(progress.unlocks, unlocks) }
end

-- `progress` with `def_names` unlocked too.
local function grant(progress: Progress, def_names: { string }): Progress
	local unlocks = set_of(progress.unlocks)
	for _, name in def_names do
		unlocks[name] = true
	end
	return { completed = set_of(progress.completed), unlocks = unlocks }
end

-- `progress` back to the starting unlocks; the missions finished stay finished.
local function relock(progress: Progress): Progress
	return { completed = set_of(progress.completed), unlocks = campaign.starting_unlocks() }
end

-- What `player` has unlocked, as a server published it on them; only the starting unlocks until it has.
local function unlocks_of(player: Player): Set
	return union(campaign.starting_unlocks(), set_of(UNLOCKS.get(player)))
end

-- The missions `player` has finished, as a server published them on them; none until it has.
local function completed_of(player: Player): Set
	return set_of(COMPLETED.get(player))
end

-- Whether a server has published `player`'s progress on them yet: until it has, they look like a new player.
local function is_published(player: Player): boolean
	return COMPLETED.get(player) ~= nil
end

-- Calls `listener` whenever what is published of `player`'s progress changes, until the returned function is called.
local function changed(player: Player, listener: () -> ()): () -> ()
	local stop_unlocks = UNLOCKS.changed(player, listener)
	local stop_completed = COMPLETED.changed(player, listener)
	return function()
		stop_unlocks()
		stop_completed()
	end
end

-- The server's side: publishes `progress` on `player`.
local function publish(player: Player, progress: Progress)
	UNLOCKS.set(player, list_of(progress.unlocks))
	COMPLETED.set(player, list_of(progress.completed))
end

return table.freeze({
	set_of = set_of,
	list_of = list_of,
	new = new,
	decode = decode,
	encode = encode,
	merge = merge,
	complete = complete,
	grant = grant,
	relock = relock,
	unlocks_of = unlocks_of,
	completed_of = completed_of,
	is_published = is_published,
	changed = changed,
	publish = publish,
})
