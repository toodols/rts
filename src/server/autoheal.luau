-- Self repair. Something whose def has an `autoheal` mends that much health a second all the time, up to its
-- full health, with no builder and no cost. It is a thing about the unit and not about what it is doing, so it
-- mends while it fights and while it moves.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local state = require(script.Parent.state)

type Entity = types.Entity

-- Everything in the world that heals itself (`state.indexed`).
local healers = state.indexed(function(def: types.EntityDef): boolean
	return def.autoheal ~= nil
end)

-- Mends everything that heals itself, a step's worth. Only finished things do: a blueprint's health follows its
-- progress.
local function tick(delta: number)
	for _, entity: Entity in healers do
		if entity.alive == false or entity.state ~= "active" then
			continue
		end
		local rate = entity.def.autoheal :: number
		if entity.health < entity.max_health then
			entity.health = math.min(entity.max_health, entity.health + rate * delta)
		end
	end
end

return table.freeze({
	tick = tick,
})
