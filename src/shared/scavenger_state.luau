--!strict
-- What the server publishes of the scavengers (server/scavengers.luau) for the clients to show: how bad it has got, the
-- difficulty the scavengers may field, which grows exponentially over the game, rounded for showing; none while the
-- gamemode is off. A replicated field (shared/replicated.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicated = require(ReplicatedStorage.Shared.replicated)

local DIFFICULTY = replicated.world("scavengers", "difficulty", replicated.NUMBER)

-- The difficulty now, or nil while the gamemode is off.
local function difficulty(): number?
	return DIFFICULTY.get()
end

-- Calls `listener` whenever the difficulty changes, until the returned function is called.
local function difficulty_changed(listener: () -> ()): () -> ()
	return DIFFICULTY.changed(listener)
end

-- The server's side.
local function publish_difficulty(shown: number?)
	DIFFICULTY.set(shown)
end

return table.freeze({
	difficulty = difficulty,
	difficulty_changed = difficulty_changed,
	publish_difficulty = publish_difficulty,
})
