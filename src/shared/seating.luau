--!strict
-- Where each player sits in the game, as both sides see it: the team they command, and whether they came only to watch,
-- a spectator, who commands none. The server seats them (server/players.luau, server/bootstrap.luau) and publishes it
-- on them (shared/replicated.luau); what the server itself goes by is its own record (players.team_of).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicated = require(ReplicatedStorage.Shared.replicated)

local TEAM = replicated.player("seat", "team", replicated.NUMBER)
local SPECTATOR = replicated.player("seat", "spectator", replicated.BOOLEAN)

-- The team `player` commands, once they have been given one.
local function team_of(player: Player): number?
	return TEAM.get(player)
end

local function is_spectator(player: Player): boolean
	return SPECTATOR.get(player) == true
end

-- Calls `listener` whenever `player`'s team changes, until the returned function is called.
local function team_changed(player: Player, listener: () -> ()): () -> ()
	return TEAM.changed(player, listener)
end

-- Calls `listener` whenever whether `player` is a spectator changes, until the returned function is called.
local function spectator_changed(player: Player, listener: () -> ()): () -> ()
	return SPECTATOR.changed(player, listener)
end

-- The server's side.

local function set_team(player: Player, team_id: number?)
	TEAM.set(player, team_id)
end

local function set_spectator(player: Player, spectator: boolean)
	SPECTATOR.set(player, if spectator then true else nil)
end

return table.freeze({
	team_of = team_of,
	is_spectator = is_spectator,
	team_changed = team_changed,
	spectator_changed = spectator_changed,
	set_team = set_team,
	set_spectator = set_spectator,
})
