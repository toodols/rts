--!strict
local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)
local palette = require(script.Parent.palette)
local footing = require(script.Parent.footing)

local studs = conversions.studs
local aoe = conversions.aoe
local capsule = conversions.capsule
local studs_per_second_squared = conversions.studs_per_second_squared
local MAP_GRAVITY = conversions.MAP_GRAVITY
local accuracy = conversions.accuracy
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity
local turn_rate = conversions.turn_rate
local shell_time = conversions.shell_time
local projectile = conversions.projectile
local missile_aoe = conversions.missile_aoe
local ROCKET_GRAVITY = conversions.ROCKET_GRAVITY
local ROCKET_DRAG = conversions.ROCKET_DRAG

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- The Janus's janus_rocket (units/ArmVehicles/armjanus.lua), one for each of its two pods on its art's turrets. A
-- rocket leaves its pod at BAR's `startvelocity`, 100 elmos a second, and speeds up at its `weaponacceleration`, 80,
-- to its `weaponvelocity`, 230, which takes (230 - 100) / 80 seconds. It `tracks`: it homes on what it was fired
-- at, turning at its `turnrate`, 22000. BAR's customparams have it go down ("descend") once it has flown its
-- `overrange_distance`, 437 elmos, and that is its guidance_time here: the (230 - 100) / 80 = 1.625s it takes to
-- reach full speed covers (100 + 230) / 2 elmos a second of it, and the rest of the 437 goes by at 230, after which
-- it steers no more and falls. Its `trajectoryheight`, 0.4, lofts it: Spring has such a missile steer for a point
-- that many times the distance above its target, sinking onto it over the flight, and so does `loft` here, which
-- takes it up over what is in the way. It does 330, its `default` damage; its 35 against aircraft is moot, since
-- BAR's onlytargetcategory SURFACE has it never shoot at them, and so is its 110 against submarines, which a rocket
-- cannot reach under the water.
local JANUS_THRUST_TIME = (230 - 100) / 80
local JANUS_GUIDANCE_TIME = JANUS_THRUST_TIME + (437 - (100 + 230) / 2 * JANUS_THRUST_TIME) / 230

local function janus_rocket(): Weapon
	return {
		kind = "missiles",
		damage = 330,
		reload = 7.5,
		range = studs(380),
		turret = { turn_rate = math.rad(200) },
		energy_per_shot = 0,
		target_layer = "ground",
		delivery = {
			kind = "straight",
			guidance = "homes",
			guidance_time = JANUS_GUIDANCE_TIME,
			loft = 0.4,
			projectile = projectile({
				speed = studs(100),
				acceleration = studs(80),
				thrust_time = JANUS_THRUST_TIME,
				aoe_radius = aoe(128),
				edge_effectiveness = 0.15,
				turn_rate = turn_rate(22000),
			}),
		},
	}
end

-- The first tier of vehicles, the ones the Vehicle Lab makes.
local defs: { [string]: EntityDef } = {
	-- corcv
	-- bar: corcv
	construction_vehicle = {
		name = "construction_vehicle",
		builder = {
			buildpower = 95,
			range = studs(130),
			assists = true,
			repairs = true,
			reclaims = true,
			options = {
				"bot_lab",
				"vehicle_lab",
				"advanced_vehicle_lab",
				"air_lab",
				"hovercraft_platform",
				"shipyard",
				"solar_collector",
				"advanced_solar_collector",
				"metal_extractor",
				"geothermal_powerplant",
				"energy_storage",
				"metal_storage",
				"energy_converter",
				"wind_turbine",
				"tidal_generator",
				"construction_turret",
				"guard",
				"wall",
				"thistle",
				"twin_guard",
				"warden",
				"agitator",
			},
		},
		footing = footing.moves "TANK3",
		weight_class = "light",
		display_name = "Construction Vehicle",
		kind = "unit",
		category = "vehicles",
		tech_level = 1,
		-- 35 x 32 x 49 elmos
		collider = capsule(35, 32, 49),
		metal_cost = 145,
		energy_cost = 2100,
		buildpower_cost = 4160,
		health = 1430,
		acceleration = studs_per_second_squared(0.03049),
		max_speed = studs(51),
		color = palette.AMBER,
	},

	-- corgator, Cortex's light laser tank
	-- bar: corgator
	incisor = {
		name = "incisor",
		footing = footing.moves "TANK2",
		weight_class = "light",
		display_name = "Incisor",
		subtitle = "Laser tank",
		kind = "unit",
		category = "vehicles",
		tech_level = 1,
		-- 23 x 24 x 33 elmos
		collider = capsule(23, 24, 33),
		metal_cost = 120,
		energy_cost = 1100,
		buildpower_cost = 2300,
		health = 820,
		acceleration = studs_per_second_squared(0.04631),
		max_speed = studs(85),
		weapons = {
			{
				kind = "laser",
				damage = 75,
				reload = 0.8,
				range = studs(230),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.1,
				},
			},
		} :: { Weapon },
		color = palette.RUST,
	},

	-- cormist: a truck with two missile racks, one for the ground and one for the air, that never fire
	-- together: the ground rack does not track and the air one does, and both share the one 2.5s reload,
	-- so only whichever finds a target first gets to fire.
	-- bar: cormist
	lasher = {
		name = "lasher",
		footing = footing.moves "TANK3",
		weight_class = "light",
		display_name = "Lasher",
		subtitle = "Missile truck",
		kind = "unit",
		category = "vehicles",
		tech_level = 1,
		-- 32 x 31 x 43 elmos
		collider = capsule(32, 31, 43),
		metal_cost = 155,
		energy_cost = 2400,
		buildpower_cost = 3440,
		health = 860,
		acceleration = studs_per_second_squared(0.02208),
		max_speed = studs(52),
		weapons = {
			{
				kind = "rockets",
				damage = 63,
				reload = 2.5,
				range = studs(575),
				energy_per_shot = 0,
				target_layer = "ground",
				weapon_group = "lasher_rack",
				delivery = {
					kind = "straight",
					guidance = "leads",
					projectile = projectile({
						speed = studs(350),
						acceleration = studs(110),
						thrust_time = 1.7,
						gravity = ROCKET_GRAVITY,
						drag = ROCKET_DRAG,
						aoe_radius = missile_aoe(48),
					}),
				},
			},
			{
				kind = "aa_missiles",
				damage = 120,
				reload = 2.5,
				range = studs(700),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				target_layer = "air",
				weapon_group = "lasher_rack",
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(350),
						acceleration = studs(110),
						thrust_time = 1.7,
						aoe_radius = missile_aoe(48),
						line_thickness = 0.3,
					}),
				},
			},
		} :: { Weapon },
		color = palette.RUST,
	},

	-- corfav: a fast, fragile scout with a light laser
	-- bar: corfav
	rascal = {
		name = "rascal",
		footing = footing.moves "TANK2",
		weight_class = "light",
		display_name = "Rascal",
		subtitle = "Scout vehicle",
		kind = "unit",
		category = "vehicles",
		tech_level = 1,
		-- 16 x 16 x 26 elmos
		collider = capsule(16, 16, 26),
		metal_cost = 26,
		energy_cost = 270,
		buildpower_cost = 1150,
		health = 90,
		acceleration = studs_per_second_squared(0.2),
		max_speed = studs(153),
		weapons = {
			{
				kind = "laser",
				damage = 35,
				reload = 1.1,
				range = studs(180),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.18,
				},
			},
		} :: { Weapon },
		color = palette.ROSE,
	},

	-- corwolv: a light artillery tank. It lobs a shell high over anything in the way at targets it cannot
	-- see, and the shell is slow enough that a fast target may be gone from where it lands.
	-- bar: corwolv
	wolverine = {
		name = "wolverine",
		footing = footing.moves "TANK3",
		display_name = "Wolverine",
		subtitle = "Light artillery tank",
		kind = "unit",
		category = "vehicles",
		tech_level = 1,
		-- 28 x 22 x 38 elmos
		collider = capsule(28, 22, 38),
		metal_cost = 170,
		energy_cost = 2500,
		buildpower_cost = 3550,
		health = 750,
		acceleration = studs_per_second_squared(0.02293),
		max_speed = studs(48),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 300,
				reload = 7.1,
				range = studs(710),
				turret = { turn_rate = math.rad(120) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "high",
					projectile = projectile({
						speed = shell_speed(studs(580)),
						gravity = shell_gravity(studs_per_second_squared(0.276)),
						aoe_radius = aoe(113),
						edge_effectiveness = 0.15,
						inaccuracy = accuracy(275),
					}),
				},
			},
		} :: { Weapon },
		color = palette.ROSE,
	},

	-- corraid, Cortex's Brute: a medium assault tank with a light cannon. Everything here is BAR's.
	-- bar: corraid
	brute = {
		name = "brute",
		footing = footing.moves "TANK3",
		weight_class = "light",
		display_name = "Brute",
		subtitle = "Medium assault tank",
		kind = "unit",
		category = "vehicles",
		tech_level = 1,
		-- 32 x 24 x 32 elmos
		collider = capsule(32, 24, 32),
		metal_cost = 235,
		energy_cost = 2400,
		buildpower_cost = 3900,
		health = 2000,
		acceleration = studs_per_second_squared(0.04056),
		max_speed = studs(72),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 97,
				reload = 1.2,
				range = studs(350),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(225)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(48),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.RUST,
	},

	-- armjanus, Arm's Janus, from units/ArmVehicles/armjanus.lua: a slow truck with two rocket pods, BAR's
	-- janus_rocket ("Heavy g2g dual-missile launcher") twice over, the second slaved to the first (`slaveto`), so
	-- both go off at whatever the first aims at: 330 damage each every 7.5s, out to 380 elmos, a 128 elmo blast (see
	-- janus_rocket above). Here they are two weapons, one on each side, that reload alike and so fire together. Its
	-- collision volume is a box 25 wide, 12 high and 33 long. Everything here is BAR's.
	-- bar: armjanus
	janus = {
		name = "janus",
		footing = footing.moves "TANK3",
		weight_class = "light",
		display_name = "Janus",
		subtitle = "Twin rocket launcher",
		kind = "unit",
		category = "vehicles",
		tech_level = 1,
		-- 25 x 12 x 33 elmos
		collider = capsule(25, 12, 33),
		metal_cost = 240,
		energy_cost = 2600,
		buildpower_cost = 3550,
		health = 1030,
		acceleration = studs_per_second_squared(0.02111),
		max_speed = studs(54),
		weapons = {
			janus_rocket(),
			janus_rocket(),
		},
		color = palette.STEEL_BLUE,
	},

	-- corlevlr, Cortex's Pounder, from units/CorVehicles/corlevlr.lua: a slow riot tank with a stubby cannon, BAR's
	-- corlevlr_weapon ("RiotCannon"): 190 damage every 1.8s out to 315 elmos, a shell at 540 elmos a second under the
	-- map's gravity, and a big, flat blast, `areaofeffect` 144 with 0.9 of its damage left at the edge, for crowds of
	-- light units. Its `impulsefactor` is moot, since nothing here is knocked about by a blast. It is `burnblow` with a
	-- `flighttime` of 0.534s, so a shell that has struck nothing by then bursts where it is (`fuse`, through shell_time,
	-- since the shell flies faster here): about 288 elmos along, short of its range, so at the edge of its reach it
	-- bursts in front of what it is fired at and the blast does the rest. Its turret turns at BAR's `turretspeedy`, 170
	-- degrees a second; its `turretspeedx`, the barrel's pitch, is not modelled here. Only at what is on the ground
	-- (onlytargetcategory SURFACE): its 27 against aircraft and 70 against submarines never apply. Its collision
	-- volume is a box 29 wide, 20 high and 32 long. Everything else here is BAR's.
	-- bar: corlevlr
	pounder = {
		name = "pounder",
		footing = footing.moves "TANK3",
		weight_class = "light",
		display_name = "Pounder",
		subtitle = "Anti swarm tank",
		kind = "unit",
		category = "vehicles",
		tech_level = 1,
		-- 29 x 20 x 32 elmos
		collider = capsule(29, 20, 32),
		metal_cost = 220,
		energy_cost = 2600,
		buildpower_cost = 3100,
		health = 1400,
		acceleration = studs_per_second_squared(0.01654),
		max_speed = studs(40),
		weapons = {
			{
				-- a Cannon, which BAR's plasma deflectors stop, as every other cannon here is
				kind = "plasma_cannon",
				damage = 190,
				reload = 1.8,
				range = studs(315),
				turret = { turn_rate = math.rad(170) },
				energy_per_shot = 0,
				target_layer = "ground",
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(540)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(144),
						edge_effectiveness = 0.9,
						fuse = shell_time(0.534),
					}),
				},
			},
		} :: { Weapon },
		color = palette.RUST,
	},
}

return table.freeze(defs)
