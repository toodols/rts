--!strict
-- How big the world is drawn: its grid, and how BAR's lengths come over into studs.

-- The heightmap grid. 4 studs matches Roblox's terrain voxel resolution exactly, so deformation
-- rewrites voxels one-to-one with the cells it edits.
local CELL_STUDS = 4
-- BAR measures distance in elmos. One stud is 11 of them, because the Peewee's 22 elmo wide collision cylinder is a 2
-- stud wide capsule; every length brought over from BAR, units and maps alike, goes through this one number.
local ELMOS_PER_STUD = 11
-- BAR gives a map's size in map units of 512 elmos each, this many studs.
local MAP_UNIT_STUDS = 512 / ELMOS_PER_STUD

return table.freeze({
	CELL_STUDS = CELL_STUDS,
	ELMOS_PER_STUD = ELMOS_PER_STUD,
	MAP_UNIT_STUDS = MAP_UNIT_STUDS,
})
