-- Warp: while it is on, the simulation runs as many steps as it can fit into a real-time budget every
-- Heartbeat, back to back, instead of waiting for real time to catch up between them one at a time -
-- a fast-forward, not a speed multiplier tied to the server's own frame rate. Like Minecraft's
-- `/tick sprint`, it is started for a set number of ticks and switches itself off once they have all
-- run, or earlier if stopped. It is a debugging aid driven by the pow `warp` and `unwarp` commands,
-- so nothing about a normal game depends on it.

-- How many ticks are still left to warp through: 0 when not warping, math.huge for a warp with no end
-- of its own.
local remaining = 0

local function is_warping(): boolean
	return remaining > 0
end

local function ticks_remaining(): number
	return remaining
end

-- Warps through `ticks` more ticks, replacing whatever warp was already running; nil warps until
-- stopped.
local function start(ticks: number?)
	remaining = if ticks == nil then math.huge else math.max(math.floor(ticks), 0)
end

local function stop()
	remaining = 0
end

-- Claims one tick of the warp for the step about to run. False once there is none left to claim, which
-- is also the moment the warp switches itself off.
local function take_tick(): boolean
	if remaining <= 0 then
		return false
	end
	remaining -= 1
	return true
end

return table.freeze({
	is_warping = is_warping,
	ticks_remaining = ticks_remaining,
	start = start,
	stop = stop,
	take_tick = take_tick,
})
