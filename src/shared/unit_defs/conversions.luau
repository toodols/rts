--!strict
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)
local world_scale = require(ReplicatedStorage.Shared.world_scale)

-- Turns BAR's numbers into this game's, so a def can be written with the numbers exactly as its BAR unit file has
-- them and each one checked against the source.
--
-- Every def names the BAR unit it is written from on a `-- bar: <unit>` line (`-- bar: none` for one that has none),
-- and a number in it that is not that unit's as its file has it says so on its own line, with one of three marks, so
-- that a search finds every one:
--
-- `-- divergence from bar`: changed from BAR's on purpose, as the game's design wants it.
-- `-- derived:` worked out from BAR's numbers, where BAR has none to copy, and how.
-- `-- not bar's:` chosen here, where BAR has none or has another, and nobody has yet said it should differ. These are
--   the ones to check against BAR's files.
--
-- Most of these conversions are exact; the few that change BAR's numbers (the blast, shell and altitude scales below)
-- are marked the same way, made once here for every def rather than def by def.
-- BAR measures distance in elmos (world_scale.ELMOS_PER_STUD to the stud) and acceleration per frame at 30 frames a
-- second; every length, speed and acceleration below goes through that one number.
local ELMOS_PER_STUD = world_scale.ELMOS_PER_STUD
local FRAMES_PER_SECOND = 30

-- Buildings are sized in cells of the building grid, not in studs, so every one is a whole number of
-- cells across and fills the cells it stands on exactly.
local function cells(count: number): number
	return count * world_scale.CELL_STUDS
end

local function studs(elmos: number): number
	return elmos / ELMOS_PER_STUD
end

-- BAR's blasts come out oversized here, so every weapon's area of effect is this fraction of its BAR radius.
local AOE_SCALE = 1 / 3 -- not bar's

-- A blast's radius, from BAR's `areaofeffect` in elmos.
local function aoe(elmos: number): number
	return studs(elmos) * AOE_SCALE
end

-- The light missiles and rockets, the anti-air ones and the Aggravator's and the Lasher's, burst narrower still: a
-- third again of what `aoe` makes of BAR's radius.
local MISSILE_AOE_DIVISOR = 3 -- not bar's

-- Such a missile's blast radius, from BAR's `areaofeffect` in elmos.
local function missile_aoe(elmos: number): number
	return (studs(elmos) / MISSILE_AOE_DIVISOR) * AOE_SCALE
end

-- A unit's collider, from its BAR collision volume in elmos: a capsule as tall as the volume and as wide
-- as its longer horizontal side, converted like everything else rather than rounded to whole studs. It keeps the
-- volume's two sides as well, for the art pipeline.
local function capsule(width: number, height: number, length: number): types.CapsuleCollider
	return {
		shape = "capsule",
		radius = studs(math.max(width, length) / 2),
		height = studs(height),
		width = studs(width),
		length = studs(length),
	}
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
local SHELL_WEIGHT = 2 -- not bar's

-- A shell's launch speed, from BAR's converted to studs: faster by the square root of SHELL_WEIGHT.
local function shell_speed(studs_per_second: number): number
	return studs_per_second * math.sqrt(SHELL_WEIGHT)
end

-- A shell's gravity, from BAR's converted to studs: SHELL_WEIGHT times as hard.
local function shell_gravity(gravity: number): number
	return gravity * SHELL_WEIGHT
end

-- A time in a shell's flight, from BAR's seconds (a `flighttime`): shorter by the square root of SHELL_WEIGHT, since
-- the shell flies its arc that much faster, so it is at the same place along it when the time is up.
local function shell_time(seconds: number): number
	return seconds / math.sqrt(SHELL_WEIGHT)
end

-- How far a plane with BAR's `turnradius` of `turn_radius` holds its heading past a goal that is behind it, before
-- it turns back for it: the engine takes it as that many frames of flight at its `speed` (elmos a second), up
-- to 1000 elmos.
local function run_out(turn_radius: number, speed: number): number
	return studs(math.min(1000, turn_radius * speed / FRAMES_PER_SECOND))
end

-- How many times as high as BAR's `cruisealtitude` every aircraft flies, since BAR's heights read too low here.
local AIR_ALTITUDE_SCALE = 2 -- divergence from bar

-- An aircraft's altitude, from BAR's `cruisealtitude` in elmos: what it flies at, what a pilot's ceiling is reckoned
-- from and what the HUD shows.
local function altitude(elmos: number): number
	return studs(elmos) * AIR_ALTITUDE_SCALE
end

-- BAR's rockets fly straight until their `flighttime` is up; here a rocket falls, once its thrust is spent, under
-- this gravity and slowed by this drag (`types.ProjectileParams`), so that one that misses comes down short.
local ROCKET_GRAVITY = 12 -- not bar's
local ROCKET_DRAG = 0.02 -- not bar's

-- What a def writes of a projectile: what `types.ProjectileParams` has, where thrust, gravity and drag may be left out
-- for none of them, as a bolt or a beam-like missile has.
export type ProjectileSpec = {
	speed: number,
	acceleration: number?,
	thrust_time: number?,
	gravity: number?,
	drag: number?,
	aoe_radius: number,
	edge_effectiveness: number?,
	inaccuracy: number?,
	turn_rate: number?,
	fuse: number?,
	line_thickness: number?,
	look: types.ProjectileLook?,
}

-- A projectile as `spec` writes it, with none of the thrust, gravity or drag it leaves out.
local function projectile(spec: ProjectileSpec): types.ProjectileParams
	return {
		speed = spec.speed,
		acceleration = spec.acceleration or 0,
		thrust_time = spec.thrust_time or 0,
		gravity = spec.gravity or 0,
		drag = spec.drag or 0,
		aoe_radius = spec.aoe_radius,
		edge_effectiveness = spec.edge_effectiveness,
		inaccuracy = spec.inaccuracy,
		turn_rate = spec.turn_rate,
		fuse = spec.fuse,
		line_thickness = spec.line_thickness,
		look = spec.look,
	}
end

-- A missile that goes up, over and down onto its target (`types.MissileDelivery`), firing `shot`. BAR steers its
-- vertical launchers by `turnrate` and `weapontimer`, which this game's flight does not have, so how high it climbs and
-- how steeply it comes down are chosen: a "short" one, a tactical missile's or a heavy rocket's, climbs 40 studs and
-- dives at least 60 degrees; a "long" one, a nuke's, climbs 300 studs and dives at least 80.
local function missile(reach: "short" | "long", shot: types.ProjectileParams): types.MissileDelivery
	local long = reach == "long"
	return {
		kind = "missile",
		climb = if long then 300 else 40, -- not bar's
		dive_angle = math.rad(if long then 80 else 60), -- not bar's
		projectile = shot,
	}
end

-- BAR's `accuracy` as the half angle, in radians, of the cone a shot may stray within: Spring reads it
-- as a fraction of 0xafff of a half turn.
local function accuracy(value: number): number
	return value * math.pi / 0xafff
end

-- A weapon's BAR `turnrate`, how fast a guided missile turns, in radians a second. Spring counts angles in 65536ths of
-- a turn and reads a weapon's turnrate as that many a second (it scales it by TAANG2RAD / GAME_SPEED to the frame).
local function turn_rate(value: number): number
	return value * 2 * math.pi / 65536
end

return table.freeze({
	cells = cells,
	studs = studs,
	aoe = aoe,
	missile_aoe = missile_aoe,
	capsule = capsule,
	altitude = altitude,
	ROCKET_GRAVITY = ROCKET_GRAVITY,
	ROCKET_DRAG = ROCKET_DRAG,
	projectile = projectile,
	missile = missile,
	studs_per_second_squared = studs_per_second_squared,
	MAP_GRAVITY = MAP_GRAVITY,
	run_out = run_out,
	accuracy = accuracy,
	turn_rate = turn_rate,
	shell_speed = shell_speed,
	shell_gravity = shell_gravity,
	shell_time = shell_time,
})
