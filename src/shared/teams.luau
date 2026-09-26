--!strict
-- The team ids that are not a side anyone plays: NEUTRAL, which owns what belongs to nobody (rocks, trees, wrecks, the
-- tutorial's boulder), and SCAVENGER, the scavengers' own team (see server/scavengers.luau). Every other team is a
-- player's or an AI's, a side of the game (`is_playable`). Team ids are handed out past the reserved ones
-- (server/players.luau), so no side is ever given one of them.

local NEUTRAL = 0
local SCAVENGER = 100

local function is_reserved(team_id: number): boolean
	return team_id == NEUTRAL or team_id == SCAVENGER
end

-- Whether `team_id` is a real side: a player's or an AI's, not the neutral team or the scavengers.
local function is_playable(team_id: number): boolean
	return is_reserved(team_id) == false
end

-- The first team id from `from` on that is not reserved.
local function next_free(from: number): number
	local team_id = from
	while is_reserved(team_id) do
		team_id += 1
	end
	return team_id
end

return table.freeze({
	NEUTRAL = NEUTRAL,
	SCAVENGER = SCAVENGER,
	is_reserved = is_reserved,
	is_playable = is_playable,
	next_free = next_free,
})
