--!strict
-- Where something of a def rests on the map as it is now: what the defs say about the water (`types.Footing`) put
-- together with the ground under it. Kept out of unit_defs, which is data and knows nothing of the map.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local ground_levels = require(ReplicatedStorage.Shared.ground_levels)
local heightmap = require(ReplicatedStorage.Shared.heightmap)
local types = require(ReplicatedStorage.Shared.types)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)

type EntityDef = types.EntityDef

-- The height its underside rests at at (x, z): the ground under it, or for something that rides the water, the
-- water's surface where that is higher, so a ship or a shipyard sits on the sea while a building that is built
-- underwater stands on the sea floor. A submarine rides its `waterline` under the surface instead, and on the sea floor
-- where the water is not that deep. A hovercraft rides the surface like a ship where there is water, and the ground
-- where there is not.
local function height(def: EntityDef, x: number, z: number): number
	local ground = heightmap.height_at(x, z)
	if unit_defs.rides_surface(def) then
		return math.max(ground, ground_levels.WATER_LEVEL - def.footing.waterline)
	end
	return ground
end

-- The point at (x, z) that something of this def rests at: `height` there. Waypoints for a ship lie on the water and
-- not on the sea floor beneath it.
local function position(def: EntityDef, x: number, z: number): Vector3
	return Vector3.new(x, height(def, x, z), z)
end

return table.freeze({
	height = height,
	position = position,
})
