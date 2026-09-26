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
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity
local projectile = conversions.projectile
local missile = conversions.missile
local missile_aoe = conversions.missile_aoe

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- The ships the Shipyard and the Advanced Shipyard make.
local defs: { [string]: EntityDef } = {
	-- corcs: builds on the water. It makes a shipyard, a metal extractor on the sea floor, and the land labs on the
	-- shore.
	-- bar: corcs
	construction_ship = {
		name = "construction_ship",
		display_name = "Construction Ship",
		kind = "unit",
		category = "ships",
		tech_level = 1,
		-- 30 x 26 x 47 elmos
		collider = capsule(30, 26, 47),
		metal_cost = 200,
		energy_cost = 2000,
		buildpower_cost = 3700,
		health = 1080,
		builder = {
			buildpower = 125,
			assists = true,
			repairs = true,
			reclaims = true,
			options = {
				"shipyard",
				"advanced_shipyard",
				"seaplane_platform",
				"bot_lab",
				"vehicle_lab",
				"air_lab",
				"metal_extractor",
				"tidal_generator",
				"urchin",
				"coral",
				"slingshot",
			},
		},
		acceleration = studs_per_second_squared(0.03567),
		max_speed = studs(60),
		footing = footing.ship("BOAT3", studs(15)),
		color = palette.AMBER,
	},

	-- coresupp: a light gunboat with a laser at each end, each aiming on its own
	-- bar: coresupp
	supporter = {
		name = "supporter",
		display_name = "Supporter",
		subtitle = "Light gun boat",
		kind = "unit",
		category = "ships",
		tech_level = 1,
		-- 20 x 16 x 40 elmos
		collider = capsule(20, 16, 40),
		metal_cost = 100,
		energy_cost = 1000,
		buildpower_cost = 1400,
		health = 480,
		acceleration = studs_per_second_squared(0.11054),
		max_speed = studs(109.8),
		footing = footing.ship("BOAT3", studs(4)),
		weapons = {
			{
				kind = "laser",
				damage = 41,
				reload = 0.93,
				range = studs(280),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.16,
				},
			},
			{
				kind = "laser",
				damage = 41,
				reload = 0.93,
				range = studs(280),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.16,
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- corpship: a gunboat with a single light cannon. Its shell falls under gravity and is aimed along the low arc,
	-- so it needs a clear line to its target, and a friend in the way stops it. Everything here is BAR's.
	-- bar: corpship
	riptide = {
		name = "riptide",
		display_name = "Riptide",
		subtitle = "Gun ship",
		kind = "unit",
		category = "ships",
		tech_level = 1,
		-- 25 x 24 x 71 elmos
		collider = capsule(25, 24, 71),
		metal_cost = 420,
		energy_cost = 2800,
		buildpower_cost = 4550,
		health = 2350,
		acceleration = studs_per_second_squared(0.04391),
		max_speed = studs(82.5),
		footing = footing.ship("BOAT4", studs(6)),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 96,
				reload = 0.8,
				range = studs(480),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(340)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(48),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- corroy (units/CorShips/corroy.lua), Cortex's Oppressor: the destroyer. A heavy plasma cannon on a turret for
	-- what is on the water and the land (onlytargetcategory SURFACE, so its 45 against aircraft never applies), whose
	-- shell falls under gravity along the low arc, as the Riptide's does, and a depth charge launcher for what is in
	-- the water. The cannon's turret turns at 60 degrees a second (its script, scripts/Units/corroy.bos); the depth
	-- charge has no turret there, and BAR lets it fire nearly all round (`maxangledif` 179), so it fires whichever way
	-- its target is. The depth charge leaves at BAR's launch speed and gains its acceleration toward BAR's top speed,
	-- homing (`tracks`) for BAR's `flighttime`. Everything here is BAR's.
	-- bar: corroy
	oppressor = {
		name = "oppressor",
		display_name = "Oppressor",
		subtitle = "Destroyer",
		kind = "unit",
		category = "ships",
		tech_level = 1,
		-- 34 x 34 x 82 elmos
		collider = capsule(34, 34, 82),
		metal_cost = 960,
		energy_cost = 7200,
		buildpower_cost = 10600,
		health = 3950,
		acceleration = studs_per_second_squared(0.02757),
		max_speed = studs(62.4),
		footing = footing.ship("BOAT4", studs(12)),
		weapons = {
			-- plasma
			{
				kind = "plasma_cannon",
				damage = 385,
				reload = 2.5,
				range = studs(710),
				turret = { turn_rate = math.rad(60) },
				energy_per_shot = 0,
				target_layer = "ground",
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(320)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(64),
						edge_effectiveness = 0.15,
					}),
				},
			},
			-- depthcharge
			{
				kind = "depth_charge",
				damage = 225,
				reload = 1.9,
				range = studs(400),
				energy_per_shot = 0,
				delivery = {
					kind = "torpedo",
					guidance = "homes",
					guidance_time = 3,
					projectile = projectile({
						speed = studs(120),
						acceleration = studs(20),
						thrust_time = (140 - 120) / 20,
						aoe_radius = aoe(24),
						edge_effectiveness = 0.9,
					}),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- legnavydestro, Legion's Syracusia: a destroyer with an orange heat ray, which needs energy to fire, and a drone
	-- carrier. BAR gives it two drones; this game gives it one, to keep the count of things down, and makes up for it
	-- by making that one drone tougher and harder hitting than either of BAR's. The heat ray's area of effect is left
	-- out, as a beam has none here.
	-- bar: legnavydestro
	syracusia = {
		name = "syracusia",
		display_name = "Syracusia",
		subtitle = "Destroyer with drones",
		kind = "unit",
		category = "ships",
		tech_level = 1,
		-- 35 x 50 x 86 elmos
		collider = capsule(35, 50, 86),
		metal_cost = 875,
		energy_cost = 9500,
		buildpower_cost = 11500,
		health = 3800,
		acceleration = studs_per_second_squared(0.02757),
		max_speed = studs(58),
		footing = footing.ship("BOAT4", studs(12)),
		weapons = {
			{
				kind = "heat_ray",
				damage = 410,
				reload = 2.4,
				range = studs(700),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 17,
				delivery = {
					kind = "beam",
					time = 0.8,
					thickness = 0.35,
					color = Color3.fromRGB(255, 128, 0),
				},
			},
		} :: { Weapon },
		-- BAR's keeps two and starts with one; this one keeps one, as the Mantis does. Each is built, and paid for, as
		-- BAR's are: 15 metal and 500 energy over twenty seconds.
		carrier = {
			drone = "drone",
			count = 1,
			starting = 1,
			stockpile = { limit = 1, build_time = 20, metal = 15, energy = 500 },
			engage_range = studs(1000),
			repair_per_second = 30,
		},
		color = palette.COPPER,
	},

	-- legnavyfrigate (units/Legion/Ships/legnavyfrigate.lua), Legion's Argonaut: a frigate with a deck torpedo
	-- launcher, which fires at what is on or under the water. BAR gives it the launcher twice, as
	-- `leg_torpedo_launcher` aimed at what is level with or above it and `leg_alt_torpedo_launcher` at what is below it
	-- (their `maindir`s point opposite ways and their `maxangledif`s meet), so only one of them can ever be turned on
	-- any one target; this game does not aim by height, and has it as the one launcher. Its torpedo is
	-- `leg_torpedo_launcher`'s: it leaves at BAR's launch speed and gains its acceleration toward BAR's top speed,
	-- homing (`tracks`) for BAR's `flighttime`. BAR's missile `turnrate` is left out, as the other torpedoes' are.
	-- Everything else here is BAR's.
	-- bar: legnavyfrigate
	argonaut = {
		name = "argonaut",
		display_name = "Argonaut",
		subtitle = "Torpedo frigate",
		kind = "unit",
		category = "ships",
		tech_level = 1,
		-- 36 x 26 x 58 elmos
		collider = capsule(36, 26, 58),
		metal_cost = 370,
		energy_cost = 3700,
		buildpower_cost = 4800,
		health = 2600,
		acceleration = studs_per_second_squared(0.03),
		max_speed = studs(72),
		footing = footing.ship("BOAT4", studs(6)),
		weapons = {
			-- leg_torpedo_launcher
			{
				kind = "torpedo",
				damage = 140,
				reload = 1.3,
				range = studs(460),
				-- its script's (scripts/Units/legnavyfrigate.bos): one turret, which both of BAR's launchers aim
				turret = { turn_rate = math.rad(120) },
				energy_per_shot = 0,
				delivery = {
					kind = "torpedo",
					guidance = "homes",
					guidance_time = 3,
					projectile = projectile({
						speed = studs(200),
						acceleration = studs(2),
						thrust_time = (250 - 200) / 2,
						aoe_radius = aoe(16),
						edge_effectiveness = 0.25,
					}),
				},
			},
		} :: { Weapon },
		color = palette.COPPER,
	},

	-- corpt, Cortex's Herring: a light corvette with two missile racks, one for aircraft and one for the ground, each
	-- aiming and reloading on its own, and both homing on what they are fired at.
	-- bar: corpt
	herring = {
		name = "herring",
		display_name = "Herring",
		subtitle = "Missile corvette",
		kind = "unit",
		category = "ships",
		tech_level = 1,
		-- 20 x 20 x 60 elmos
		collider = capsule(20, 20, 60),
		metal_cost = 210,
		energy_cost = 1400,
		buildpower_cost = 2500,
		health = 890,
		acceleration = studs_per_second_squared(0.05),
		max_speed = studs(69),
		footing = footing.ship("BOAT3", studs(6)),
		weapons = {
			{
				kind = "aa_missiles",
				damage = 120,
				reload = 2,
				range = studs(750),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 0,
				target_layer = "air",
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(500),
						acceleration = studs(110),
						thrust_time = 2,
						aoe_radius = missile_aoe(48),
						line_thickness = 0.3,
					}),
				},
			},
			{
				kind = "missiles",
				damage = 47,
				reload = 2,
				range = studs(650),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 0,
				target_layer = "ground",
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(420),
						acceleration = studs(110),
						thrust_time = 2,
						aoe_radius = missile_aoe(48),
					}),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- corsub, Cortex's Orca: a submarine. It runs under the surface, where nothing but a torpedo can be aimed at it, and
	-- fires torpedoes of its own, which run straight at where their target will be. Everything here is BAR's: the
	-- torpedo leaves at BAR's launch speed and gains its acceleration until it is at BAR's top speed.
	-- bar: corsub
	orca = {
		name = "orca",
		display_name = "Orca",
		subtitle = "Submarine",
		kind = "unit",
		category = "ships",
		tech_level = 1,
		-- 35 x 22 x 50 elmos
		collider = capsule(35, 22, 50),
		metal_cost = 580,
		energy_cost = 4000,
		buildpower_cost = 7200,
		health = 1060,
		acceleration = studs_per_second_squared(0.0451),
		max_speed = studs(57),
		footing = footing.ship("UBOAT4", studs(15), studs(45)),
		weapons = {
			{
				kind = "torpedo",
				damage = 342,
				reload = 2.5,
				range = studs(500),
				energy_per_shot = 0,
				-- its tubes point ahead: a 30 degree cone
				fire_arc = math.rad(15),
				delivery = {
					kind = "torpedo",
					guidance = "leads",
					projectile = projectile({
						speed = studs(130),
						acceleration = studs(15),
						thrust_time = (200 - 130) / 15,
						aoe_radius = aoe(64),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- corcrus, Cortex's Buccaneer: a cruiser, and what there is to hunt submarines with. It has a heavy laser for
	-- what is on the water and the land, and depth charges, which BAR makes the same weapon as a torpedo, that home on
	-- what is in the water under or beside it, and BAR's lighter, quicker deck laser, which fires at aircraft too. It is
	-- BAR's second tier, built at the Advanced Shipyard. Everything else here is BAR's.
	-- bar: corcrus
	buccaneer = {
		name = "buccaneer",
		display_name = "Buccaneer",
		subtitle = "Cruiser",
		kind = "unit",
		category = "ships",
		tech_level = 2,
		-- 34 x 34 x 115 elmos
		collider = capsule(34, 34, 115),
		metal_cost = 1000,
		energy_cost = 12000,
		buildpower_cost = 23000,
		health = 6200,
		acceleration = studs_per_second_squared(0.02649),
		max_speed = studs(54),
		footing = footing.ship("BOAT5", studs(30)),
		weapons = {
			{
				kind = "laser",
				damage = 200,
				reload = 1.125,
				range = studs(500),
				turret = { turn_rate = math.rad(110) },
				energy_per_shot = 40,
				target_layer = "ground",
				delivery = {
					kind = "beam",
					time = 0.15,
					thickness = 0.4,
				},
			},
			-- adv_decklaser
			{
				kind = "laser",
				damage = 75,
				reload = 0.333,
				range = studs(430),
				turret = { turn_rate = math.rad(110) },
				energy_per_shot = 15,
				delivery = {
					kind = "beam",
					time = 0.15,
					color = Color3.new(1, 0, 0),
				},
			},
			{
				kind = "depth_charge",
				damage = 225,
				reload = 1.8,
				range = studs(450),
				turret = { turn_rate = math.rad(110) },
				energy_per_shot = 0,
				delivery = {
					kind = "torpedo",
					guidance = "homes",
					projectile = projectile({
						speed = studs(150),
						acceleration = studs(25),
						thrust_time = (225 - 150) / 25,
						aoe_radius = aoe(32),
						edge_effectiveness = 0.95,
					}),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- armseadragon (units/ArmShips/T2/armseadragon.lua), Armada's Sea Dragon: a nuclear missile submarine. It runs
	-- under the surface as the Orca does, with torpedo tubes of its own, and carries BAR's `sdmssl`, a nuke it
	-- stockpiles and launches from under the water (`waterweapon`) only at what it is told to (`commandfire`).
	-- - The nuke is BAR's in damage, blast and stockpile: ten at most, one every 140 seconds for 1000 metal and 125000
	--   energy. Its range and flight are the Apocalypse's, since BAR gives the two the same (72000 elmos, a 1600 elmos a
	--   second starburst), so it crosses the map and comes down as the silo's does.
	-- - The torpedo leaves at BAR's launch speed and gains its acceleration until it is at BAR's top speed, homing
	--   (`tracks`). BAR fires it within 35 degrees of ahead (`maxangledif`).
	-- - BAR's `nuclear_launch` is a weapon only for the launch alarm (`bogus`), and is left out, as are the
	--   per-category damages (commanders, subs).
	-- - Its death blast is BAR's `nukeSub`.
	-- Everything else here is BAR's.
	-- bar: armseadragon
	sea_dragon = {
		name = "sea_dragon",
		display_name = "Sea Dragon",
		subtitle = "Nuclear missile submarine",
		kind = "unit",
		category = "ships",
		tech_level = 2,
		-- 32 x 29 x 110 elmos
		collider = capsule(32, 29, 110),
		metal_cost = 8000,
		energy_cost = 85000,
		buildpower_cost = 190000,
		health = 2400,
		acceleration = studs_per_second_squared(0.03),
		max_speed = studs(48),
		footing = footing.ship("UBOAT4", studs(20), studs(40)),
		weapons = {
			-- waterballon
			{
				kind = "torpedo",
				damage = 800,
				reload = 8,
				range = studs(720),
				energy_per_shot = 0,
				fire_arc = math.rad(35) / 2,
				delivery = {
					kind = "torpedo",
					guidance = "homes",
					projectile = projectile({
						speed = studs(150),
						acceleration = studs(20),
						thrust_time = (290 - 150) / 20,
						aoe_radius = aoe(12),
						edge_effectiveness = 0.15,
					}),
				},
			},
			-- sdmssl
			{
				kind = "nuke",
				damage = 9500,
				reload = 30,
				range = studs(20000),
				energy_per_shot = 0,
				stockpile = { limit = 10, build_time = 140, metal = 1000, energy = 125000 },
				manual_fire = true,
				launches_underwater = true,
				-- from the hatches on its back, behind the sail
				offset = Vector3.new(0, 1, -0.8),
				delivery = missile(
					"long",
					projectile({
						speed = studs(500),
						aoe_radius = aoe(1280),
						edge_effectiveness = 0.45,
						look = {
							size = Vector3.new(1.6, 1.6, 7),
							color = Color3.fromRGB(62, 64, 70),
							material = Enum.Material.Metal,
							trail = { color = Color3.fromRGB(236, 236, 230), width = 3, lifetime = 8 },
							flame = { color = Color3.fromRGB(255, 150, 50), size = 2.6, rate = 80, lifetime = 0.4 },
							smoke = { color = Color3.fromRGB(196, 194, 190), size = 3.5, rate = 45, lifetime = 6 },
							light = { color = Color3.fromRGB(255, 170, 80), range = 30, brightness = 5 },
							explosion = "nuclear",
						},
					})
				),
			},
		} :: { Weapon },
		death_explosion = { radius = studs(780), damage = 4000 },
		color = palette.STEEL_BLUE,
	},
}

return table.freeze(defs)
