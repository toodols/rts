--!strict
-- Who the game's developers are: they may do what nobody else may, such as give a player a resource bonus in the lobby.
-- A server reads the list as each player joins and publishes whether they are on it on them (see
-- server_shared/developer_list.luau, which keeps the list), which is what `is_developer` reads, on the server or a
-- client.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicated = require(ReplicatedStorage.Shared.replicated)

local DEVELOPER = replicated.player("developer", "listed", replicated.BOOLEAN)

local function is_developer(player: Player): boolean
	return DEVELOPER.get(player) == true
end

-- Calls `listener` whenever whether `player` is a developer is published, until the returned function is called.
local function changed(player: Player, listener: () -> ()): () -> ()
	return DEVELOPER.changed(player, listener)
end

-- The server's side.
local function publish(player: Player, developer: boolean)
	DEVELOPER.set(player, developer)
end

return table.freeze({
	is_developer = is_developer,
	changed = changed,
	publish = publish,
})
