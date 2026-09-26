--!strict
-- The heights the ground and the sea are measured by, and how steep ground may be built on.

-- The ground a map is at where nothing has been built, like the highlands' mean height.
local TERRAIN_BASE_HEIGHT = 4
-- The lowest voxels the terrain is drawn from.
local TERRAIN_FLOOR_HEIGHT = -48

-- The sea. Ground below this height is under water, as deep as the ground is far under it. Whether a
-- thing may stand there is up to its def: land units cannot, amphibious ones like the commander can, and
-- ships need it.
local WATER_LEVEL = 0
-- Ground counts as dry land, for a start, a vent or scenery to be put on, only this far above the water.
local DRY_GROUND_MARGIN = 0.5
-- Something that cannot stand in water drowns if it is in it anyway, losing all its health over DROWN_SECONDS. Water
-- shallower than what it tolerates plus DROWN_DEPTH_MARGIN studs is not counted, so that a unit pushed a hair into the
-- shore is not drowned for it.
local DROWN_SECONDS = 5
local DROWN_DEPTH_MARGIN = 0.5

-- A building may only be placed where the ground under its footprint varies by less than this.
local MAX_BUILD_SLOPE_STUDS = 3

return table.freeze({
	TERRAIN_BASE_HEIGHT = TERRAIN_BASE_HEIGHT,
	TERRAIN_FLOOR_HEIGHT = TERRAIN_FLOOR_HEIGHT,
	WATER_LEVEL = WATER_LEVEL,
	DRY_GROUND_MARGIN = DRY_GROUND_MARGIN,
	DROWN_SECONDS = DROWN_SECONDS,
	DROWN_DEPTH_MARGIN = DROWN_DEPTH_MARGIN,
	MAX_BUILD_SLOPE_STUDS = MAX_BUILD_SLOPE_STUDS,
})
