--!strict
-- What each team did over the game, as the server publishes it once the game has ended (server/match_stats.luau) and
-- the end screen shows it (client/ui/victory_screen.luau): the rows, as a replicated field (shared/replicated.luau).

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local replicated = require(ReplicatedStorage.Shared.replicated)

-- One team's line.
export type TeamStats = {
	team: number,
	name: string,
	-- whether a player played it
	player: boolean,
	won: boolean,
	damage: number,
	-- what its damage took off, by the power (metal plus energy / 60) of what it hit
	destroyed: number,
	kills: number,
	lost: number,
	metal: number,
}

local ROWS = replicated.world(
	"match",
	"report",
	replicated.json(function(decoded: any): { TeamStats }?
		return if typeof(decoded) == "table" and #decoded > 0 then decoded else nil
	end)
)

-- The rows published, if they have been.
local function read(): { TeamStats }?
	return ROWS.get()
end

-- Calls `listener` whenever the rows are published or taken away, until the returned function is called.
local function changed(listener: () -> ()): () -> ()
	return ROWS.changed(listener)
end

-- The server's side: publishes `rows`, or takes them away for nil.
local function publish(rows: { TeamStats }?)
	ROWS.set(rows)
end

return table.freeze({
	read = read,
	changed = changed,
	publish = publish,
})
