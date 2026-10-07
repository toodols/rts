--!strict
-- How fast the game's time runs against real time: 1 for a game as it is played, and more to watch a replay faster
-- (server/replay.luau). The server's loop (init.server.luau) owes the simulation real time times this. Warp (warp.luau)
-- is apart from it: that runs steps back to back, as fast as they go.

-- The fastest it may run: the loop catches up at most a few steps a frame.
local MOST = 8

local rate = 1

local function get(): number
	return rate
end

-- Runs the game `value` times as fast as real time, from 0 to MOST.
local function set(value: number)
	rate = math.clamp(value, 0, MOST)
end

return table.freeze({
	MOST = MOST,
	get = get,
	set = set,
})
