-- Clearing out the dead: everything flagged dead is taken out of the world and every system that kept something
-- about it forgets it. The step does this at the end of every tick; loading a map does it at once, so the world is
-- empty before the new one is built, paused or not.

local state = require(script.Parent.state)
local instances = require(script.Parent.instances)
local production = require(script.Parent.production)
local combat = require(script.Parent.combat)
local scavengers = require(script.Parent.scavengers)
local movement = require(script.Parent.movement)
local docking = require(script.Parent.docking)

local function reap()
	for _, id in state.reap() do
		instances.destroy(id)
		production.forget(id)
		combat.forget(id)
		scavengers.forget(id)
		movement.forget(id)
		docking.forget(id)
		-- a transport that is gone takes what it was carrying with it
		state.drop_hold(id)
	end
end

return table.freeze({
	reap = reap,
})
