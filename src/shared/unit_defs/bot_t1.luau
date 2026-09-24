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

-- The first tier of bots, the ones the Bot Lab makes, and the commander.
local defs: { [string]: EntityDef } = {
	commander = {
		name = "commander",
		slope_class = "COMMANDERBOT",
		weight_class = "heavy",
		display_name = "Commander",
		kind = "unit",
		-- 28 x 52 x 28 elmos
		collider = capsule(28, 52, 28),
		metal_cost = 2700,
		energy_cost = 26000,
		buildpower_cost = 75000,
		health = 3700,
		buildpower = 300,
		acceleration = studs_per_second_squared(0.18),
		max_speed = studs(37.5),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		build_range = studs(145),
		max_water_depth = studs(5000),
		build_options = {
			"bot_lab",
			"vehicle_lab",
			"air_lab",
			"shipyard",
			"solar_collector",
			"metal_extractor",
			"energy_storage",
			"metal_storage",
			"energy_converter",
			"wind_turbine",
			"tidal_generator",
			"guard",
			"wall",
			"thistle",
			"hovercraft_platform",
		},
		-- armcomlaser
		weapons = {
			{
				damage = 75,
				reload = 0.4,
				range = studs(300),
				energy_per_shot = 0,
				beam_time = 0.1,
			},
		},
		-- the disintegrator: BAR gives it 99999 damage in a 36 elmo area, which kills anything it
		-- touches. Here it is a rectangle as long as its range, and that area is its half width.
		manual_weapon = {
			range = studs(250),
			reload = 0.9,
			energy_per_shot = 500,
			radius = studs(36),
		},
		-- armcom's own income and storage; a team with no commander has neither
		metal_income = 2,
		energy_income = 30,
		metal_storage = 500,
		energy_storage = 500,
		nametag = true,
		-- BAR's commander blast is defined in a weapon file this was not taken from, so these are chosen
		-- to be big: wide enough to take out a cluster of buildings and most of what stands near it
		death_explosion = { radius = 24, damage = 4000 },
		color = Color3.fromRGB(244, 226, 160),
	},

	construction_bot = {
		name = "construction_bot",
		slope_class = "BOT2",
		weight_class = "light",
		display_name = "Construction Bot",
		kind = "unit",
		build_range = studs(130),
		-- armck: 27 x 30 x 27 elmos
		collider = capsule(27, 30, 27),
		metal_cost = 110,
		energy_cost = 1600,
		buildpower_cost = 3450,
		health = 760,
		buildpower = 80,
		acceleration = studs_per_second_squared(0.552),
		max_speed = studs(36),
		reclaiming = true,
		repairing = true,
		resurrecting = false,
		assisting = true,
		max_water_depth = 0,
		build_options = {
			"bot_lab",
			"advanced_bot_lab",
			"vehicle_lab",
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

	grunt = {
		name = "grunt",
		slope_class = "BOT2",
		weight_class = "light",
		display_name = "Grunt",
		subtitle = "Fast infantry bot",
		kind = "unit",
		-- corak: 24 x 32 x 24 elmos
		collider = capsule(24, 32, 24),
		metal_cost = 43,
		energy_cost = 820,
		buildpower_cost = 1250,
		health = 280,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.4),
		max_speed = studs(81),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 37,
				reload = 0.5,
				range = studs(215),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				beam_time = 0.1,
			},
		},
		color = Color3.fromRGB(198, 86, 72),
	},

	-- armflea: a tiny, quick scout bot with a short-range laser
	tick = {
		name = "tick",
		slope_class = "SBOT2",
		weight_class = "light",
		display_name = "Tick",
		subtitle = "Scout bot",
		kind = "unit",
		-- 20 x 12 x 20 elmos
		collider = capsule(20, 12, 20),
		metal_cost = 21,
		energy_cost = 300,
		buildpower_cost = 800,
		health = 60,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.575),
		max_speed = studs(132),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 24,
				reload = 0.6,
				range = studs(140),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				beam_time = 0.1,
			},
		},
		color = Color3.fromRGB(150, 176, 120),
	},

	-- corthud, Cortex's Thug: a sturdy bot with a light plasma cannon. Everything here is BAR's.
	thug = {
		name = "thug",
		slope_class = "BOT3",
		weight_class = "light",
		display_name = "Thug",
		subtitle = "Light plasma bot",
		kind = "unit",
		-- 29 x 32 x 29 elmos
		collider = capsule(29, 32, 29),
		metal_cost = 140,
		energy_cost = 1150,
		buildpower_cost = 2100,
		health = 1100,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.12995),
		max_speed = studs(45),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 104,
				reload = 1.73333,
				range = studs(380),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				projectile = {
					speed = shell_speed(studs(286)),
					acceleration = 0,
					thrust_time = 0,
					gravity = shell_gravity(studs(MAP_GRAVITY)),
					drag = 0,
					aoe_radius = aoe(studs(36)),
					edge_effectiveness = 0.15,
					arc = "low",
					plasma = true,
				},
			},
		},
		color = Color3.fromRGB(196, 140, 84),
	},

	-- corstorm, Cortex's rocket bot. Its rocket thrusts for two seconds, at a launch speed and
	-- acceleration taken from BAR, and after that falls; the drag and gravity are chosen, and its blast
	-- is a third of the area BAR gives it.
	aggravator = {
		name = "aggravator",
		slope_class = "BOT2",
		weight_class = "light",
		display_name = "Aggravator",
		subtitle = "Rocket bot",
		kind = "unit",
		-- 22 x 28 x 22 elmos
		collider = capsule(22, 28, 22),
		metal_cost = 110,
		energy_cost = 1150,
		buildpower_cost = 1950,
		health = 740,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.1242),
		max_speed = studs(47.7),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 157,
				reload = 3.8,
				range = studs(475),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				projectile = {
					speed = studs(190),
					acceleration = studs(120),
					thrust_time = 2,
					gravity = 12,
					drag = 1.5,
					aoe_radius = aoe(studs(48) / 3),
				},
			},
		},
		color = Color3.fromRGB(196, 140, 84),
	},

	-- corcrash, Cortex's Trasher: a bot with a missile for aircraft and for nothing else, the same missile as the
	-- thistle's with its own numbers. BAR gives it a second weapon that does no damage and only helps it aim, which
	-- is left out. Its movement class is BAR's ABOT3, the amphibious bot: it climbs what the other bots do, and
	-- wades as the commander does.
	trasher = {
		name = "trasher",
		slope_class = "ABOT3",
		weight_class = "light",
		display_name = "Trasher",
		subtitle = "Amphibious anti air bot",
		kind = "unit",
		-- 30 x 32 x 30 elmos
		collider = capsule(30, 32, 30),
		metal_cost = 125,
		energy_cost = 1100,
		buildpower_cost = 1900,
		health = 640,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.138),
		max_speed = studs(53.49),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = studs(5000),
		build_options = nil,
		weapons = {
			{
				damage = 110,
				reload = 2,
				range = studs(760),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				anti_air = true,
				target_layer = "air",
				projectile = {
					speed = studs(650),
					acceleration = studs(141),
					thrust_time = 1.75,
					gravity = 12,
					drag = 1.5,
					aoe_radius = aoe(studs(48) / 3),
					line_thickness = 0.3,
					homing = true,
				},
			},
		},
		color = Color3.fromRGB(196, 140, 84),
	},

	-- cornecro. It can repair and reclaim and nothing else: it neither builds nor assists.
	graverobber = {
		name = "graverobber",
		slope_class = "BOT2",
		weight_class = "light",
		display_name = "Graverobber",
		subtitle = "Rezbot",
		kind = "unit",
		-- 28 x 34 x 28 elmos
		collider = capsule(28, 34, 28),
		metal_cost = 130,
		energy_cost = 1400,
		buildpower_cost = 2800,
		health = 220,
		buildpower = 200,
		acceleration = studs_per_second_squared(0.23),
		max_speed = studs(78),
		reclaiming = true,
		repairing = true,
		resurrecting = true,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = nil,
		color = Color3.fromRGB(150, 176, 120),
	},

	-- armwar: a bot with a pair of short-range lasers, one on each side, that aim on their own
	centurion = {
		name = "centurion",
		slope_class = "BOT3",
		weight_class = "light",
		display_name = "Centurion",
		subtitle = "Anti swarm bot",
		kind = "unit",
		-- 30 x 32 x 30 elmos
		collider = capsule(30, 32, 30),
		metal_cost = 270,
		energy_cost = 3100,
		buildpower_cost = 4200,
		health = 1590,
		buildpower = nil,
		acceleration = studs_per_second_squared(0.0828),
		max_speed = studs(45),
		reclaiming = false,
		repairing = false,
		resurrecting = false,
		assisting = false,
		max_water_depth = 0,
		build_options = nil,
		weapons = {
			{
				damage = 55,
				reload = 0.3,
				range = studs(325),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				beam_time = 0.12,
				offset = Vector3.new(-0.7, 1, 0),
			},
			{
				damage = 55,
				reload = 0.3,
				range = studs(325),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				beam_time = 0.12,
				offset = Vector3.new(0.7, 1, 0),
			},
		},
		color = Color3.fromRGB(120, 150, 196),
	},
}

return table.freeze(defs)
