--!strict
-- The local player's campaign progress, as whichever server they are on published it on their Player (the lobby's
-- or a game's, see shared/campaign_progress.luau): what they have unlocked and the missions they have finished. In a
-- game anything locked is shown as locked in the build menu, and nothing on the client starts placing or queuing it
-- (the server refuses it anyway); in the lobby the campaign screen and the encyclopedia show it.

local Players = game:GetService "Players"
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local campaign = require(ReplicatedStorage.Shared.campaign)
local campaign_progress = require(ReplicatedStorage.Shared.campaign_progress)

local use_store = require(ReplicatedStorage.ClientShared.use_store)

export type Standing = {
	unlocks: { [string]: boolean },
	completed: { [string]: boolean },
}

local player = Players.LocalPlayer

-- The local player's progress as it is now.
local function read(): Standing
	return {
		unlocks = campaign_progress.unlocks_of(player),
		completed = campaign_progress.completed_of(player),
	}
end

-- Whether the local player may build `def_name`.
local function is_unlocked(def_name: string): boolean
	return campaign.is_unlocked(campaign_progress.unlocks_of(player), def_name)
end

-- Calls `listener` whenever the local player's progress changes. Returns a function that stops it.
local function subscribe(listener: () -> ()): () -> ()
	return campaign_progress.changed(player, listener)
end

-- The local player's progress, as a hook that follows it as it changes.
local function use_standing(): Standing
	return use_store.use_store(read, subscribe)
end

return table.freeze({
	read = read,
	is_unlocked = is_unlocked,
	subscribe = subscribe,
	use_standing = use_standing,
})
