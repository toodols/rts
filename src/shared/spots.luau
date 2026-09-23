-- Which spots a spot-bound building stands on: an extractor on metal spots, a geothermal plant on vents. Placement asks
-- this rather than either kind itself, so the two are placed, snapped and counted as taken in the one way.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local metal_spots = require(ReplicatedStorage.Shared.metal_spots)
local geo_spots = require(ReplicatedStorage.Shared.geo_spots)

export type Spots = {
	nearest: (x: number, z: number, radius: number, skip: ((position: Vector3) -> boolean)?) -> Vector3?,
}

-- The spots `def` has to be built on, or nil for something that can go anywhere.
local function for_def(def: types.EntityDef): Spots?
	if def.requires_metal_spot == true then
		return metal_spots
	end
	if def.requires_geo_spot == true then
		return geo_spots
	end
	return nil
end

-- Whether `a` and `b` are bound to the same kind of spot, and so compete for the same ones.
local function same_kind(a: types.EntityDef, b: types.EntityDef): boolean
	local spots = for_def(a)
	return spots ~= nil and spots == for_def(b)
end

-- Whether `def` is built over something of `other_def_name` in place, which then does not stand in its way.
local function upgrades(def: types.EntityDef, other_def_name: string): boolean
	return def.upgrades ~= nil and table.find(def.upgrades, other_def_name) ~= nil
end

return table.freeze({
	for_def = for_def,
	same_kind = same_kind,
	upgrades = upgrades,
})
