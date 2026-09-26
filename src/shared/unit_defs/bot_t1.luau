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
local missile_aoe = conversions.missile_aoe
local ROCKET_GRAVITY = conversions.ROCKET_GRAVITY
local ROCKET_DRAG = conversions.ROCKET_DRAG

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- The first tier of bots, the ones the Bot Lab makes, and the commander.
local defs: { [string]: EntityDef } = {
	-- bar: armcom
	commander = {
		name = "commander",
		footing = footing.moves "COMMANDERBOT",
		weight_class = "heavy",
		display_name = "Commander",
		kind = "unit",
		category = "bots",
		tech_level = 1,
		role = "commander",
		-- 28 x 52 x 28 elmos
		collider = capsule(28, 52, 28),
		metal_cost = 2700,
		energy_cost = 26000,
		buildpower_cost = 75000,
		health = 3700,
		builder = {
			buildpower = 300,
			range = studs(145),
			assists = true,
			repairs = true,
			reclaims = true,
			options = {
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
		},
		acceleration = studs_per_second_squared(0.18),
		max_speed = studs(37.5),
		-- armcom's `paralyzemultiplier` 0
		emp_resistance = 1,
		-- armcomlaser
		weapons = {
			{
				kind = "laser",
				damage = 75,
				reload = 0.4,
				range = studs(300),
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.1,
				},
			},
		} :: { Weapon },
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
		-- big enough to take out a cluster of buildings and most of what stands near it
		-- not bar's: armcom's commanderexplosion is 700 elmos across and 5000 damage
		death_explosion = { radius = 24, damage = 4000 },
		color = Color3.fromRGB(244, 226, 160),
	},

	-- bar: armck
	construction_bot = {
		name = "construction_bot",
		footing = footing.moves "BOT2",
		weight_class = "light",
		display_name = "Construction Bot",
		kind = "unit",
		category = "bots",
		tech_level = 1,
		builder = {
			buildpower = 80,
			range = studs(130),
			assists = true,
			repairs = true,
			reclaims = true,
			options = {
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
		},
		-- armck: 27 x 30 x 27 elmos
		collider = capsule(27, 30, 27),
		metal_cost = 110,
		energy_cost = 1600,
		buildpower_cost = 3450,
		health = 760,
		acceleration = studs_per_second_squared(0.552),
		max_speed = studs(36),
		color = palette.AMBER,
	},

	-- bar: corak
	grunt = {
		name = "grunt",
		footing = footing.moves "BOT2",
		weight_class = "light",
		display_name = "Grunt",
		subtitle = "Fast infantry bot",
		kind = "unit",
		category = "bots",
		tech_level = 1,
		-- corak: 24 x 32 x 24 elmos
		collider = capsule(24, 32, 24),
		metal_cost = 43,
		energy_cost = 820,
		buildpower_cost = 1250,
		health = 280,
		acceleration = studs_per_second_squared(0.4),
		max_speed = studs(81),
		weapons = {
			{
				kind = "laser",
				damage = 37,
				reload = 0.5,
				range = studs(215),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.1,
				},
			},
		} :: { Weapon },
		color = palette.BRICK,
	},

	-- armflea: a tiny, quick scout bot with a short-range laser
	-- bar: armflea
	tick = {
		name = "tick",
		footing = footing.moves "SBOT2",
		weight_class = "light",
		display_name = "Tick",
		subtitle = "Scout bot",
		kind = "unit",
		category = "bots",
		tech_level = 1,
		-- 20 x 12 x 20 elmos
		collider = capsule(20, 12, 20),
		metal_cost = 21,
		energy_cost = 300,
		buildpower_cost = 800,
		health = 60,
		acceleration = studs_per_second_squared(0.575),
		max_speed = studs(132),
		weapons = {
			{
				kind = "laser",
				damage = 24,
				reload = 0.6,
				range = studs(140),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.1,
				},
			},
		} :: { Weapon },
		color = palette.OLIVE,
	},

	-- corthud, Cortex's Thug: a sturdy bot with a light plasma cannon. Everything here is BAR's.
	-- bar: corthud
	thug = {
		name = "thug",
		footing = footing.moves "BOT3",
		weight_class = "light",
		display_name = "Thug",
		subtitle = "Light plasma bot",
		kind = "unit",
		category = "bots",
		tech_level = 1,
		-- 29 x 32 x 29 elmos
		collider = capsule(29, 32, 29),
		metal_cost = 140,
		energy_cost = 1150,
		buildpower_cost = 2100,
		health = 1100,
		acceleration = studs_per_second_squared(0.12995),
		max_speed = studs(45),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 104,
				reload = 1.73333,
				range = studs(380),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(286)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(36),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.COPPER,
	},

	-- corstorm, Cortex's rocket bot. Its rocket thrusts for two seconds, at a launch speed and
	-- acceleration taken from BAR, and after that falls; the drag and gravity are chosen, and its blast
	-- is a third of the area BAR gives it.
	-- bar: corstorm
	aggravator = {
		name = "aggravator",
		footing = footing.moves "BOT2",
		weight_class = "light",
		display_name = "Aggravator",
		subtitle = "Rocket bot",
		kind = "unit",
		category = "bots",
		tech_level = 1,
		-- 22 x 28 x 22 elmos
		collider = capsule(22, 28, 22),
		metal_cost = 110,
		energy_cost = 1150,
		buildpower_cost = 1950,
		health = 740,
		acceleration = studs_per_second_squared(0.1242),
		max_speed = studs(47.7),
		weapons = {
			{
				kind = "rockets",
				damage = 157,
				reload = 3.8,
				range = studs(475),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				delivery = {
					kind = "straight",
					guidance = "none",
					projectile = projectile({
						speed = studs(190),
						acceleration = studs(120),
						thrust_time = 2,
						gravity = ROCKET_GRAVITY,
						drag = ROCKET_DRAG,
						aoe_radius = missile_aoe(48),
					}),
				},
			},
		} :: { Weapon },
		color = palette.COPPER,
	},

	-- corcrash, Cortex's Trasher: a bot with a missile for aircraft and for nothing else, the same missile as the
	-- thistle's with its own numbers. BAR gives it a second weapon that does no damage and only helps it aim, which
	-- is left out. Its movement class is BAR's ABOT3, the amphibious bot: it climbs what the other bots do, and
	-- wades as the commander does.
	-- bar: corcrash
	trasher = {
		name = "trasher",
		footing = footing.moves "ABOT3",
		weight_class = "light",
		display_name = "Trasher",
		subtitle = "Amphibious anti air bot",
		kind = "unit",
		category = "bots",
		tech_level = 1,
		-- 30 x 32 x 30 elmos
		collider = capsule(30, 32, 30),
		metal_cost = 125,
		energy_cost = 1100,
		buildpower_cost = 1900,
		health = 640,
		acceleration = studs_per_second_squared(0.138),
		max_speed = studs(53.49),
		weapons = {
			{
				kind = "aa_missiles",
				damage = 110,
				reload = 2,
				range = studs(760),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				target_layer = "air",
				delivery = {
					kind = "straight",
					guidance = "homes",
					projectile = projectile({
						speed = studs(650),
						acceleration = studs(141),
						thrust_time = 1.75,
						gravity = ROCKET_GRAVITY,
						drag = ROCKET_DRAG,
						aoe_radius = missile_aoe(48),
						line_thickness = 0.3,
					}),
				},
			},
		} :: { Weapon },
		color = palette.COPPER,
	},

	-- cornecro. It can repair and reclaim and nothing else: it neither builds nor assists.
	-- bar: cornecro
	graverobber = {
		name = "graverobber",
		footing = footing.moves "BOT2",
		weight_class = "light",
		display_name = "Graverobber",
		subtitle = "Rezbot",
		kind = "unit",
		category = "bots",
		tech_level = 1,
		-- 28 x 34 x 28 elmos
		collider = capsule(28, 34, 28),
		metal_cost = 130,
		energy_cost = 1400,
		buildpower_cost = 2800,
		health = 220,
		builder = {
			buildpower = 200,
			range = studs(96),
			repairs = true,
			reclaims = true,
			resurrects = true,
		},
		acceleration = studs_per_second_squared(0.23),
		max_speed = studs(78),
		color = palette.OLIVE,
	},

	-- armwar: a bot with a pair of short-range lasers, one on each side, that aim on their own
	-- bar: armwar
	centurion = {
		name = "centurion",
		footing = footing.moves "BOT3",
		weight_class = "light",
		display_name = "Centurion",
		subtitle = "Anti swarm bot",
		kind = "unit",
		category = "bots",
		tech_level = 1,
		-- 30 x 32 x 30 elmos
		collider = capsule(30, 32, 30),
		metal_cost = 270,
		energy_cost = 3100,
		buildpower_cost = 4200,
		health = 1590,
		acceleration = studs_per_second_squared(0.0828),
		max_speed = studs(45),
		weapons = {
			{
				kind = "laser",
				damage = 55,
				reload = 0.3,
				range = studs(325),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.12,
				},
			},
			{
				kind = "laser",
				damage = 55,
				reload = 0.3,
				range = studs(325),
				turret = { turn_rate = math.rad(240) },
				energy_per_shot = 0,
				delivery = {
					kind = "beam",
					time = 0.12,
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},
}

return table.freeze(defs)
