local ReplicatedStorage = game:GetService "ReplicatedStorage"

local types = require(ReplicatedStorage.Shared.types)

local conversions = require(script.Parent.conversions)

local studs = conversions.studs
local aoe = conversions.aoe
local capsule = conversions.capsule
local studs_per_second_squared = conversions.studs_per_second_squared
local MAP_GRAVITY = conversions.MAP_GRAVITY
local accuracy = conversions.accuracy
local shell_speed = conversions.shell_speed
local shell_gravity = conversions.shell_gravity

type EntityDef = types.EntityDef

-- The second tier of vehicles, the ones the Advanced Vehicle Lab makes, and the Mantis's drone.
local defs: { [string]: EntityDef } = {
	advanced_construction_vehicle = {
		name = "advanced_construction_vehicle",
		slope_class = "TANK3",
		build_range = studs(136),
		vehicle = true,
		display_name = "Advanced Construction Vehicle",
		kind = "unit",
		collider = capsule(36, 36, 47),
		metal_cost = 580,
		energy_cost = 7000,
		buildpower_cost = 17000,
		health = 2150,
		buildpower = 310,
		acceleration = studs_per_second_squared(0.02547),
		max_speed = studs(49.5),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = 0,
		build_options = {
			"vehicle_lab",
			"advanced_vehicle_lab",
			"advanced_metal_extractor",
			"advanced_geothermal_powerplant",
			"rampart",
			"advanced_energy_converter",
			"scorpion",
			"pulsar",
			"persecutor",
			"eradicator",
			"catalyst",
			"prevailer",
			"apocalypse",
			"overseer",
			"calamity",
			"fusion_reactor",
			"advanced_fusion_reactor",
			"epic_fusion_reactor",
			"experimental_gantry",
			"epic_energy_converter",
			"advanced_construction_turret",
			"hardened_energy_storage",
			"hardened_metal_storage",
			"screamer",
		},
		color = Color3.fromRGB(226, 178, 74),
	},

	-- cormart: a heavier artillery tank whose shells hit harder and burst wider than the Wolverine's. BAR
	-- has it fire along the low arc; it is set to the high one here.
	-- legvcarry: a drone carrier. It has no gun of its own; it keeps two drones on its back and sends them at
	-- whatever comes within a thousand elmos. Its movement class is BAR's HTANK4.
	mantis = {
		name = "mantis",
		slope_class = "HTANK4",
		vehicle = true,
		display_name = "Mantis",
		subtitle = "Drone carrier",
		kind = "unit",
		-- 55 x 37 x 67 elmos
		collider = capsule(55, 37, 67),
		metal_cost = 450,
		energy_cost = 9000,
		buildpower_cost = 11550,
		health = 1400,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02),
		max_speed = studs(45),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(12),
		build_options = nil,
		weapons = nil,
		-- BAR's keeps six and starts with three; this one keeps one, much tougher (see the drone). Each is built, and
		-- paid for, as BAR's are: 15 metal and 500 energy over ten seconds.
		carrier = {
			drone = "drone",
			count = 1,
			starting = 1,
			stockpile = { limit = 1, build_time = 10, metal = 15, energy = 500 },
			engage_range = studs(1000),
			repair_per_second = 30,
		},
		color = Color3.fromRGB(120, 150, 196),
	},

	-- legdrone: what a Mantis carries. It is quick and hard to hit, and its laser is weak but not nothing. A Mantis
	-- keeps only two, so each has three times BAR's health and one and a half times its damage: the pair is as
	-- tough as BAR's six but does half the damage, which is what it takes to keep them from being too much. Nothing
	-- builds it: its carrier makes it. BAR's two-shot burst is one shot of twice the damage there.
	drone = {
		name = "drone",
		display_name = "Drone",
		subtitle = "Combat drone",
		kind = "unit",
		drone = true,
		-- 20 x 20 x 20 elmos, its footprint being one
		collider = capsule(20, 20, 20),
		metal_cost = 15,
		energy_cost = 500,
		buildpower_cost = 1000,
		health = 300,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.35),
		max_speed = studs(280.5),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(9999),
		build_options = nil,
		air = { altitude = 7, climb_speed = 20 },
		weapons = {
			{
				damage = 24,
				reload = 0.9,
				range = studs(300),
				energy_per_shot = 0,
				beam_time = 0.1,
			},
		},
		color = Color3.fromRGB(226, 226, 120),
	},

	quaker = {
		name = "quaker",
		slope_class = "TANK3",
		vehicle = true,
		display_name = "Quaker",
		subtitle = "Mobile artillery",
		kind = "unit",
		-- 38 x 24 x 41 elmos
		collider = capsule(38, 24, 41),
		metal_cost = 400,
		energy_cost = 4400,
		buildpower_cost = 9000,
		health = 1200,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.03),
		max_speed = studs(58),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 420,
				reload = 5,
				range = studs(800),
				turret = { turn_rate = math.rad(120) },
				energy_per_shot = 0,
				projectile = {
					speed = shell_speed(studs(349)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(144)),
					edge_effectiveness = 0.65,
					arc = "high",
					plasma = true,
					inaccuracy = accuracy(640),
				},
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},

	-- corvroc, Cortex's Negotiator: the Arbiter's rocket on a truck, heavier and slower to reload. It flies the way the
	-- Arbiter's does, straight up, over and down, with the same chosen climb and dive.
	negotiator = {
		name = "negotiator",
		slope_class = "HTANK4",
		vehicle = true,
		weight_class = "heavy",
		display_name = "Negotiator",
		subtitle = "Rocket launcher",
		kind = "unit",
		-- 40 x 40 x 44 elmos
		collider = capsule(40, 40, 44),
		metal_cost = 880,
		energy_cost = 6700,
		buildpower_cost = 20000,
		health = 1390,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02489),
		max_speed = studs(33),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 1700,
				reload = 16,
				range = studs(1310),
				turret = { turn_rate = math.rad(90) },
				energy_per_shot = 0,
				projectile = {
					speed = studs(415),
					acceleration = 0,
					thrust_time = 0,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(150)),
					edge_effectiveness = 0.65,
					missile = { climb = 40, dive_angle = math.rad(60) },
				},
			},
		},
		color = Color3.fromRGB(196, 140, 84),
	},

	-- correap, Cortex's Tiger: a quick, tough heavy tank with a fast-firing cannon, good at most jobs. Everything here
	-- is BAR's.
	tiger = {
		name = "tiger",
		slope_class = "MTANK3",
		vehicle = true,
		weight_class = "heavy",
		display_name = "Tiger",
		subtitle = "Heavy assault tank",
		kind = "unit",
		-- 34 x 34 x 38 elmos
		collider = capsule(34, 34, 38),
		metal_cost = 690,
		energy_cost = 10000,
		buildpower_cost = 16000,
		health = 5300,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.0362),
		max_speed = studs(69),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 109,
				reload = 0.7,
				range = studs(410),
				turret = { turn_rate = math.rad(130) },
				energy_per_shot = 0,
				projectile = {
					speed = shell_speed(studs(380)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(64)),
					edge_effectiveness = 0.15,
					arc = "low",
					plasma = true,
				},
			},
		},
		color = Color3.fromRGB(176, 122, 88),
	},

	-- corparrow, Cortex's Poison Arrow: an amphibious heavy tank that drives along the sea floor as readily as on land,
	-- with a slow, hard-hitting cannon. Its movement class is BAR's ATANK3. Everything here is BAR's.
	poison_arrow = {
		name = "poison_arrow",
		slope_class = "ATANK3",
		vehicle = true,
		weight_class = "heavy",
		display_name = "Poison Arrow",
		subtitle = "Amphibious heavy tank",
		kind = "unit",
		-- 44 x 35 x 53 elmos
		collider = capsule(44, 35, 53),
		metal_cost = 1050,
		energy_cost = 21000,
		buildpower_cost = 26000,
		health = 6300,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.0266),
		max_speed = studs(51),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(5000),
		build_options = nil,
		weapons = {
			{
				damage = 370,
				reload = 1.8,
				range = studs(575),
				turret = { turn_rate = math.rad(130) },
				energy_per_shot = 0,
				projectile = {
					speed = shell_speed(studs(300)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(160)),
					edge_effectiveness = 0.15,
					arc = "low",
					plasma = true,
				},
			},
		},
		color = Color3.fromRGB(150, 176, 120),
	},
}

return table.freeze(defs)
