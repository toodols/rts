local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)

local studs = conversions.studs
local aoe = conversions.aoe
local capsule = conversions.capsule
local studs_per_second_squared = conversions.studs_per_second_squared
local MAP_GRAVITY = conversions.MAP_GRAVITY
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity

type EntityDef = types.EntityDef

-- The first tier of ships, the ones the Shipyard makes.
local defs: { [string]: EntityDef } = {
	-- corcs: builds on the water. It makes a shipyard, and a metal extractor on the sea floor.
	construction_ship = {
		name = "construction_ship",
		display_name = "Construction Ship",
		subtitle = "Builder ship",
		kind = "unit",
		-- 30 x 26 x 47 elmos
		collider = capsule(30, 26, 47),
		metal_cost = 200,
		energy_cost = 2000,
		buildpower_cost = 3700,
		health = 1080,
		buildpower = 125,
		acceleration = studs_per_second_squared(0.03567),
		max_speed = studs(60),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = studs(9999),
		min_water_depth = studs(15),
		build_options = { "shipyard", "metal_extractor", "tidal_generator" },
		weapons = nil,
		color = Color3.fromRGB(226, 178, 74),
	},

	-- coresupp: a light gunboat with a laser at each end, each aiming on its own
	supporter = {
		name = "supporter",
		display_name = "Supporter",
		subtitle = "Light gun boat",
		kind = "unit",
		-- 20 x 16 x 40 elmos
		collider = capsule(20, 16, 40),
		metal_cost = 100,
		energy_cost = 1000,
		buildpower_cost = 1400,
		health = 480,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.11054),
		max_speed = studs(109.8),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(4),
		build_options = nil,
		weapons = {
			{
				damage = 41,
				reload = 0.93,
				range = studs(280),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				beam_time = 0.16,
				offset = Vector3.new(0, 1, 1.4),
			},
			{
				damage = 41,
				reload = 0.93,
				range = studs(280),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				beam_time = 0.16,
				offset = Vector3.new(0, 1, -1.4),
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- corpship: a gunboat with a single light cannon. Its shell falls under gravity and is aimed along the low arc,
	-- so it needs a clear line to its target, and a friend in the way stops it. Everything here is BAR's.
	riptide = {
		name = "riptide",
		display_name = "Riptide",
		subtitle = "Gun ship",
		kind = "unit",
		-- 25 x 24 x 71 elmos
		collider = capsule(25, 24, 71),
		metal_cost = 420,
		energy_cost = 2800,
		buildpower_cost = 4550,
		health = 2350,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.04391),
		max_speed = studs(82.5),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(6),
		build_options = nil,
		weapons = {
			{
				damage = 96,
				reload = 0.8,
				range = studs(480),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 0,
				projectile = {
					speed = shell_speed(studs(340)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(48)),
					edge_effectiveness = 0.15,
					arc = "low",
					plasma = true,
				},
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},

	-- legnavydestro, Legion's Syracusia: a destroyer with an orange heat ray, which needs energy to fire, and a drone
	-- carrier. BAR gives it two drones; this game gives it one, to keep the count of things down, and makes up for it
	-- by making that one drone tougher and harder hitting than either of BAR's. The heat ray's area of effect is left
	-- out, as a beam has none here.
	syracusia = {
		name = "syracusia",
		display_name = "Syracusia",
		subtitle = "Destroyer with drones",
		kind = "unit",
		-- 35 x 50 x 86 elmos
		collider = capsule(35, 50, 86),
		metal_cost = 875,
		energy_cost = 9500,
		buildpower_cost = 11500,
		health = 3800,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02757),
		max_speed = studs(58),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(12),
		build_options = nil,
		weapons = {
			{
				damage = 410,
				reload = 2.4,
				range = studs(700),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 17,
				beam_time = 0.8,
				beam_thickness = 0.35,
				beam_color = Color3.fromRGB(255, 128, 0),
			},
		},
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
		color = Color3.fromRGB(196, 140, 84),
	},

	-- corpt, Cortex's Herring: a light corvette with two missile racks, one for aircraft and one for the ground, each
	-- aiming and reloading on its own, and both homing on what they are fired at.
	herring = {
		name = "herring",
		display_name = "Herring",
		subtitle = "Missile corvette",
		kind = "unit",
		-- 20 x 20 x 60 elmos
		collider = capsule(20, 20, 60),
		metal_cost = 210,
		energy_cost = 1400,
		buildpower_cost = 2500,
		health = 890,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.05),
		max_speed = studs(69),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(6),
		build_options = nil,
		weapons = {
			{
				damage = 120,
				reload = 2,
				range = studs(750),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 0,
				anti_air = true,
				target_layer = "air",
				offset = Vector3.new(0, 1.5, 1),
				projectile = {
					speed = studs(500),
					acceleration = studs(110),
					thrust_time = 2,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(48) / 3),
					line_thickness = 0.3,
					homing = true,
				},
			},
			{
				damage = 47,
				reload = 2,
				range = studs(650),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 0,
				target_layer = "ground",
				offset = Vector3.new(0, 1.5, -1),
				projectile = {
					speed = studs(420),
					acceleration = studs(110),
					thrust_time = 2,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(48) / 3),
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},

	-- corsub, Cortex's Orca: a submarine. It runs under the surface, where nothing but a torpedo can be aimed at it, and
	-- fires torpedoes of its own, which run straight at where their target will be. Everything here is BAR's: the
	-- torpedo leaves at BAR's launch speed and gains its acceleration until it is at BAR's top speed.
	orca = {
		name = "orca",
		display_name = "Orca",
		subtitle = "Submarine",
		kind = "unit",
		-- 35 x 22 x 50 elmos
		collider = capsule(35, 22, 50),
		metal_cost = 580,
		energy_cost = 4000,
		buildpower_cost = 7200,
		health = 1060,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.0451),
		max_speed = studs(57),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(15),
		waterline = studs(45),
		build_options = nil,
		weapons = {
			{
				damage = 342,
				reload = 2.5,
				range = studs(500),
				energy_per_shot = 0,
				projectile = {
					speed = studs(130),
					acceleration = studs(15),
					thrust_time = (200 - 130) / 15,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(64)),
					edge_effectiveness = 0.15,
					torpedo = true,
					leads = true,
				},
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},

	-- corcrus, Cortex's Buccaneer: a cruiser, and what there is to hunt submarines with. It has a heavy laser for
	-- what is on the water and the land, and depth charges, which BAR makes the same weapon as a torpedo, that home on
	-- what is in the water under or beside it. BAR's lighter deck laser is left out. Everything else here is BAR's.
	buccaneer = {
		name = "buccaneer",
		display_name = "Buccaneer",
		subtitle = "Cruiser",
		kind = "unit",
		-- 34 x 34 x 115 elmos
		collider = capsule(34, 34, 115),
		metal_cost = 1000,
		energy_cost = 12000,
		buildpower_cost = 23000,
		health = 6200,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02649),
		max_speed = studs(54),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		min_water_depth = studs(30),
		build_options = nil,
		weapons = {
			{
				damage = 200,
				reload = 1.125,
				range = studs(500),
				turret = { turn_rate = math.rad(110) },
				energy_per_shot = 40,
				target_layer = "ground",
				offset = Vector3.new(0, 2.5, 2),
				beam_time = 0.15,
				beam_thickness = 0.4,
			},
			{
				damage = 225,
				reload = 1.8,
				range = studs(450),
				turret = { turn_rate = math.rad(110) },
				energy_per_shot = 0,
				offset = Vector3.new(0, 1, -3),
				projectile = {
					speed = studs(150),
					acceleration = studs(25),
					thrust_time = (225 - 150) / 25,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(32)),
					edge_effectiveness = 0.95,
					torpedo = true,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},
}

return table.freeze(defs)
