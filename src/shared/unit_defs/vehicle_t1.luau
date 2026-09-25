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

-- The first tier of vehicles, the ones the Vehicle Lab makes.
local defs: { [string]: EntityDef } = {
	-- corcv
	construction_vehicle = {
		name = "construction_vehicle",
		build_range = studs(130),
		slope_class = "TANK3",
		vehicle = true,
		weight_class = "light",
		display_name = "Construction Vehicle",
		kind = "unit",
		-- 35 x 32 x 49 elmos
		collider = capsule(35, 32, 49),
		metal_cost = 145,
		energy_cost = 2100,
		buildpower_cost = 4160,
		health = 1430,
		buildpower = 95,
		acceleration = studs_per_second_squared(0.03049),
		max_speed = studs(51),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = 0,
		build_options = {
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
		weapons = nil,
		color = Color3.fromRGB(226, 178, 74),
	},

	-- corgator, Cortex's light laser tank
	incisor = {
		name = "incisor",
		slope_class = "TANK2",
		vehicle = true,
		weight_class = "light",
		display_name = "Incisor",
		subtitle = "Laser tank",
		kind = "unit",
		-- 23 x 24 x 33 elmos
		collider = capsule(23, 24, 33),
		metal_cost = 120,
		energy_cost = 1100,
		buildpower_cost = 2300,
		health = 820,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.04631),
		max_speed = studs(85),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 75,
				reload = 0.8,
				range = studs(230),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				beam_time = 0.1,
			},
		},
		color = Color3.fromRGB(176, 122, 88),
	},

	-- cormist: a truck with two missile racks, one for the ground and one for the air, that never fire
	-- together: the ground rack does not track and the air one does, and both share the one 2.5s reload,
	-- so only whichever finds a target first gets to fire.
	lasher = {
		name = "lasher",
		slope_class = "TANK3",
		vehicle = true,
		weight_class = "light",
		display_name = "Lasher",
		subtitle = "Missile truck",
		kind = "unit",
		-- 32 x 31 x 43 elmos
		collider = capsule(32, 31, 43),
		metal_cost = 155,
		energy_cost = 2400,
		buildpower_cost = 3440,
		health = 860,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02208),
		max_speed = studs(52),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 63,
				reload = 2.5,
				range = studs(575),
				energy_per_shot = 0,
				target_layer = "ground",
				weapon_group = "lasher_rack",
				projectile = {
					speed = studs(350),
					acceleration = studs(110),
					thrust_time = 1.7,
					gravity = 12,
					drag = 0.02,
					aoe_radius = aoe(studs(48) / 3),
					leads = true,
				},
			},
			{
				damage = 120,
				reload = 2.5,
				range = studs(700),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				anti_air = true,
				target_layer = "air",
				weapon_group = "lasher_rack",
				offset = Vector3.new(0, 2, 0),
				projectile = {
					speed = studs(350),
					acceleration = studs(110),
					thrust_time = 1.7,
					gravity = 0,
					drag = 0,
					aoe_radius = aoe(studs(48) / 3),
					line_thickness = 0.3,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(176, 122, 88),
	},

	-- corfav: a fast, fragile scout with a light laser
	rascal = {
		name = "rascal",
		slope_class = "TANK2",
		vehicle = true,
		weight_class = "light",
		display_name = "Rascal",
		subtitle = "Scout vehicle",
		kind = "unit",
		-- 16 x 16 x 26 elmos
		collider = capsule(16, 16, 26),
		metal_cost = 26,
		energy_cost = 270,
		buildpower_cost = 1150,
		health = 90,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.2),
		max_speed = studs(153),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 35,
				reload = 1.1,
				range = studs(180),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				beam_time = 0.18,
			},
		},
		color = Color3.fromRGB(196, 96, 80),
	},

	-- corwolv: a light artillery tank. It lobs a shell high over anything in the way at targets it cannot
	-- see, and the shell is slow enough that a fast target may be gone from where it lands.
	wolverine = {
		name = "wolverine",
		slope_class = "TANK3",
		vehicle = true,
		display_name = "Wolverine",
		subtitle = "Light artillery tank",
		kind = "unit",
		-- 28 x 22 x 38 elmos
		collider = capsule(28, 22, 38),
		metal_cost = 170,
		energy_cost = 2500,
		buildpower_cost = 3550,
		health = 750,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.02293),
		max_speed = studs(48),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 300,
				reload = 7.1,
				range = studs(710),
				turret = { turn_rate = math.rad(120) },
				energy_per_shot = 0,
				projectile = {
					speed = shell_speed(studs(580)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs_per_second_squared(0.276)),
					drag = 0,
					aoe_radius = aoe(studs(113)),
					edge_effectiveness = 0.15,
					arc = "high",
					plasma = true,
					inaccuracy = accuracy(275),
				},
			},
		},
		color = Color3.fromRGB(196, 96, 80),
	},

	-- corraid, Cortex's Brute: a medium assault tank with a light cannon. Everything here is BAR's.
	brute = {
		name = "brute",
		slope_class = "TANK3",
		vehicle = true,
		weight_class = "light",
		display_name = "Brute",
		subtitle = "Medium assault tank",
		kind = "unit",
		-- 32 x 24 x 32 elmos
		collider = capsule(32, 24, 32),
		metal_cost = 235,
		energy_cost = 2400,
		buildpower_cost = 3900,
		health = 2000,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.04056),
		max_speed = studs(72),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 97,
				reload = 1.2,
				range = studs(350),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				projectile = {
					speed = shell_speed(studs(225)),
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
		color = Color3.fromRGB(176, 122, 88),
	},
}

return table.freeze(defs)
