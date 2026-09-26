--!strict
-- The simulation runs on a fixed step so that build rates, reload timers and acceleration are
-- independent of frame rate. Render frames interpolate between steps on the client.

local TICK_RATE = 20
local TICK_DELTA = 1 / TICK_RATE

return table.freeze({
	TICK_RATE = TICK_RATE,
	TICK_DELTA = TICK_DELTA,
})
