--!strict
-- A blueprint nobody has built on for BLUEPRINT_DECAY_DELAY seconds starts to fall apart, losing
-- BLUEPRINT_DECAY_RATE build progress a second and refunding the metal that progress cost. Once it is back to nothing
-- it disappears (server/construction.luau; the client draws the decay on its bar).

local BLUEPRINT_DECAY_DELAY = 5
local BLUEPRINT_DECAY_RATE = 30

return table.freeze({
	BLUEPRINT_DECAY_DELAY = BLUEPRINT_DECAY_DELAY,
	BLUEPRINT_DECAY_RATE = BLUEPRINT_DECAY_RATE,
})
