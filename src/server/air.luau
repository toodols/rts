-- Aircraft. Whether something is one, and how high it is off the ground.
--
-- An aircraft takes off and lands straight up and down: it rests on the ground like anything else, climbs to
-- its flying altitude when it has somewhere to go, and settles back down once it has been idle a while.
-- `movement` does the flying; this only says where the ground is under it and whether it has left it.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)
local unit_defs = require(ReplicatedStorage.Shared.unit_defs)
local heightmap = require(ReplicatedStorage.Shared.heightmap)

type Entity = types.Entity
type EntityDef = types.EntityDef

-- How far above where it rests an aircraft has to be before it counts as flying.
local AIRBORNE_MARGIN = 1
-- How many points round the edge of something the ground is read at, for how high it rests.
local FOOTPRINT_SAMPLES = 8

-- The height the middle of `def` is at when it rests on the ground at (x, z): on the highest of the ground under
-- it, round the edge of its collider as well as under its middle, so that one over a slope or a cliff edge does
-- not sink into the side that rises. It never goes under the sea: an aircraft that lands over the water hovers on
-- its surface.
local function resting_height(def: EntityDef, x: number, z: number): number
	local ground = math.max(heightmap.height_at(x, z), config.WATER_LEVEL)
	local radius = unit_defs.collider_radius(def)
	for index = 0, FOOTPRINT_SAMPLES - 1 do
		local angle = index * (2 * math.pi / FOOTPRINT_SAMPLES)
		ground = math.max(ground, heightmap.height_at(x + math.cos(angle) * radius, z + math.sin(angle) * radius))
	end
	return ground + unit_defs.collider_height(def) / 2
end

-- Whether it is an aircraft, in the air or not. A wreck is not: what an aircraft leaves behind is on the ground.
local function is_aircraft(entity: Entity): boolean
	return entity.kind == "unit" and unit_defs.is_air(unit_defs.of(entity))
end

-- Whether it is off the ground, which is what puts it out of the way of things that stand on it.
local function is_airborne(entity: Entity): boolean
	if is_aircraft(entity) == false then
		return false
	end
	local def = unit_defs.of(entity)
	return entity.position.Y > resting_height(def, entity.position.X, entity.position.Z) + AIRBORNE_MARGIN
end

return table.freeze({
	resting_height = resting_height,
	is_aircraft = is_aircraft,
	is_airborne = is_airborne,
})
