-- Self repair. Something whose def has an `autoheal` mends that much health a second all the time, up to its
-- full health, with no builder and no cost. It is a thing about the unit and not about what it is doing, so it
-- mends while it fights and while it moves.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

local state = require(script.Parent.state)

type Entity = types.Entity

-- Mends everything that heals itself, a step's worth. Only finished things do: a blueprint's health follows its
-- progress, and a wreck has none to mend.
local function tick(delta: number)
	for _, entity: Entity in state.all() do
		if entity.alive == false or entity.state ~= "active" or entity.kind == "wreck" then
			continue
		end
		local rate = unit_defs.get(entity.def_name).autoheal
		if rate ~= nil and entity.health < entity.max_health then
			entity.health = math.min(entity.max_health, entity.health + rate * delta)
		end
	end
end

return table.freeze({
	tick = tick,
})
