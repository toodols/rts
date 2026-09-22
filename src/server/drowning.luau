-- Drowning. Something that cannot stand in water and finds itself in it anyway, pushed there by a physics quirk or
-- put there by whatever set it down, cannot be prevented from doing so, so it is made to drown instead: it
-- loses its health at a steady rate that takes all of it in `config.DROWN_SECONDS`, whatever its size, and
-- goes on doing so for as long as it is in water too deep for it. Getting out in time saves it, and what it lost
-- stays lost.
--
-- Only ground units can drown. A ship stranded on land is not in water, an aircraft is over it and not in it, and
-- a building is never moved, so it is only ever put in water by a placement that `placement` refuses.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

local state = require(script.Parent.state)
local combat = require(script.Parent.combat)

type Entity = types.Entity

-- Whether `entity` is standing in water that is too deep for its def.
local function is_drowning(entity: Entity): boolean
	if entity.kind ~= "unit" or entity.state ~= "active" or entity.alive == false then
		return false
	end
	local def = unit_defs.get(entity.def_name)
	if unit_defs.is_air(def) then
		return false
	end
	local depth = heightmap.water_depth(entity.position.X, entity.position.Z)
	return depth > def.max_water_depth + config.DROWN_DEPTH_MARGIN
end

-- Drowns everything in water it cannot stand in, a step's worth. Run once a step, after everything has moved.
local function tick(delta: number)
	for _, entity in state.all() do
		if is_drowning(entity) then
			combat.apply_damage(entity, entity.max_health / config.DROWN_SECONDS * delta)
		end
	end
end

return table.freeze({
	is_drowning = is_drowning,
	tick = tick,
})
