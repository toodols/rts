local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local config = require(ReplicatedStorage.Shared.config)

-- Turns BAR's numbers into this game's, so a def can be written with the numbers exactly as its BAR unit file has
-- them and each one checked against the source.

-- BAR measures distance in elmos (config.ELMOS_PER_STUD to the stud) and acceleration per frame at 30 frames a
-- second; every length, speed and acceleration below goes through that one number.
local ELMOS_PER_STUD = config.ELMOS_PER_STUD
local FRAMES_PER_SECOND = 30

-- Buildings are sized in cells of the building grid, not in studs, so every one is a whole number of
-- cells across and fills the cells it stands on exactly.
local function cells(count: number): number
	return count * config.CELL_STUDS
end

local function studs(elmos: number): number
	return elmos / ELMOS_PER_STUD
end

-- BAR's blasts come out oversized here, so every weapon's area of effect is this fraction of its BAR radius.
local AOE_SCALE = 1 / 3

local function aoe(radius: number): number
	return radius * AOE_SCALE
end

-- A unit's collider, from its BAR collision volume in elmos: a capsule as tall as the volume and as wide
-- as its longer horizontal side, converted like everything else rather than rounded to whole studs.
local function capsule(width: number, height: number, length: number): types.CapsuleCollider
	return { shape = "capsule", radius = studs(math.max(width, length) / 2), height = studs(height) }
end

-- BAR's acceleration is elmos per frame per frame; this is studs per second per second.
local function studs_per_second_squared(elmos_per_frame_squared: number): number
	return studs(elmos_per_frame_squared * FRAMES_PER_SECOND * FRAMES_PER_SECOND)
end

-- Spring's map gravity, in elmos per second squared: what a weapon with no gravity of its own falls under.
local MAP_GRAVITY = 130

-- How many times as hard a shell falls here as in BAR. BAR's own gravity came out feeling too light, so a shell is
-- made heavier, and is fired the square root of this faster to make up for it: an arc's shape is set by its speed
-- squared over its gravity, so it flies the same arc as in BAR, reaches as far and lands as near its aim, only
-- faster and falling harder. Nothing but a shell that arcs is changed.
local SHELL_WEIGHT = 2

-- A shell's launch speed, from BAR's converted to studs: faster by the square root of SHELL_WEIGHT.
local function shell_speed(studs_per_second: number): number
	return studs_per_second * math.sqrt(SHELL_WEIGHT)
end

-- A shell's gravity, from BAR's converted to studs: SHELL_WEIGHT times as hard.
local function shell_gravity(gravity: number): number
	return gravity * SHELL_WEIGHT
end

-- How far a plane with BAR's `turnradius` of `turn_radius` holds its heading past a goal that is behind it, before
-- it turns back for it: the engine takes it as that many frames of flight at its `speed` (elmos a second), up
-- to 1000 elmos.
local function run_out(turn_radius: number, speed: number): number
	return studs(math.min(1000, turn_radius * speed / FRAMES_PER_SECOND))
end

-- BAR's `accuracy` as the half angle, in radians, of the cone a shot may stray within: Spring reads it
-- as a fraction of 0xafff of a half turn.
local function accuracy(value: number): number
	return value * math.pi / 0xafff
end

return table.freeze({
	cells = cells,
	studs = studs,
	aoe = aoe,
	capsule = capsule,
	studs_per_second_squared = studs_per_second_squared,
	MAP_GRAVITY = MAP_GRAVITY,
	run_out = run_out,
	accuracy = accuracy,
	shell_speed = shell_speed,
	shell_gravity = shell_gravity,
})
