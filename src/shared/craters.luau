--!strict
-- Explosions press a crater into the ground as deep as they are strong: the deepest a single one goes is
-- DEFORM_MAX_DEPTH studs, which only the heaviest blasts approach (depth is that times
-- 1 - e^(-(damage / DEFORM_DAMAGE_SCALE) ^ DEFORM_DAMAGE_POWER)), and blasts too weak to make DEFORM_MIN_DEPTH are
-- ignored. The power keeps a light weapon's crater far shallower than a heavy one's: a first-tier gun's shells (under
-- about 150 damage) leave none, a riot tank's or a rocket's (200 to 330) a dent a few hundredths of a stud deep, heavy
-- artillery (1500 and up) over a stud. With every shell a fixed share as deep, a unit under a light gun's fire sank
-- until the rim hid it from every straight or low-arc shot, and a Pounder lost to the Janus it should beat. Ground
-- pushed aside piles up in a rim from the crater's edge out to DEFORM_RIM_REACH times its radius, DEFORM_RIM_FRACTION
-- as high as the crater is deep. A blast too small to cover a grid cell is treated as one of DEFORM_MIN_RADIUS. Blasts
-- in one place keep digging deeper, down to DEFORM_FLOOR_HEIGHT, which leaves solid ground above the lowest voxels the
-- terrain is drawn from (ground_levels.TERRAIN_FLOOR_HEIGHT); rims never pile up more than DEFORM_MAX_RISE studs above
-- where the map generated them.

local ReplicatedStorage = game:GetService "ReplicatedStorage"

local world_scale = require(ReplicatedStorage.Shared.world_scale)
local ground_levels = require(ReplicatedStorage.Shared.ground_levels)

local DEFORM_FLOOR_HEIGHT = ground_levels.TERRAIN_FLOOR_HEIGHT + world_scale.CELL_STUDS * 2
local DEFORM_MAX_DEPTH = 2
local DEFORM_DAMAGE_SCALE = 1500
local DEFORM_DAMAGE_POWER = 2
local DEFORM_MIN_DEPTH = 0.02
local DEFORM_RIM_FRACTION = 0.3
local DEFORM_RIM_REACH = 1.6
local DEFORM_MIN_RADIUS = world_scale.CELL_STUDS * 1.5
local DEFORM_MAX_RISE = 4

return table.freeze({
	DEFORM_MAX_DEPTH = DEFORM_MAX_DEPTH,
	DEFORM_DAMAGE_SCALE = DEFORM_DAMAGE_SCALE,
	DEFORM_DAMAGE_POWER = DEFORM_DAMAGE_POWER,
	DEFORM_MIN_DEPTH = DEFORM_MIN_DEPTH,
	DEFORM_RIM_FRACTION = DEFORM_RIM_FRACTION,
	DEFORM_RIM_REACH = DEFORM_RIM_REACH,
	DEFORM_MIN_RADIUS = DEFORM_MIN_RADIUS,
	DEFORM_MAX_RISE = DEFORM_MAX_RISE,
	DEFORM_FLOOR_HEIGHT = DEFORM_FLOOR_HEIGHT,
})
