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
local ROCKET_GRAVITY = conversions.ROCKET_GRAVITY
local ROCKET_DRAG = conversions.ROCKET_DRAG

type EntityDef = types.EntityDef
type Weapon = types.Weapon

-- The second tier of bots, the ones the Advanced Bot Lab makes.
local defs: { [string]: EntityDef } = {
	-- bar: corack
	advanced_construction_bot = {
		name = "advanced_construction_bot",
		footing = footing.moves "BOT2",
		display_name = "Advanced Construction Bot",
		weight_class = "light",
		kind = "unit",
		category = "bots",
		tech_level = 2,
		builder = {
			buildpower = 220,
			range = studs(136),
			assists = true,
			repairs = true,
			reclaims = true,
			options = {
				"bot_lab",
				"advanced_bot_lab",
				"advanced_metal_extractor",
				"advanced_geothermal_powerplant",
				"rampart",
				"advanced_energy_converter",
				"scorpion",
				"pulsar",
				"persecutor",
				"catalyst",
				"apocalypse",
				"prevailer",
				"overseer",
				"wall",
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
		},
		collider = capsule(28, 42, 30),
		metal_cost = 470,
		energy_cost = 6900,
		energy_income = 14,
		energy_storage = 100,
		buildpower_cost = 12500,
		health = 1000,
		acceleration = studs_per_second_squared(0.4692),
		max_speed = studs(33),
		color = palette.AMBER,
	},

	-- corhrk, Cortex's Arbiter: a heavy rocket bot. BAR's rocket climbs steeply and comes down on its target from
	-- above; here it flies as the missile launchers' do, straight up, over to the target and down onto it, so nothing
	-- in the way stops it. The climb and dive are chosen: BAR does not give them.
	-- bar: corhrk
	arbiter = {
		name = "arbiter",
		footing = footing.moves "BOT3",
		weight_class = "light",
		display_name = "Arbiter",
		subtitle = "Heavy rocket bot",
		kind = "unit",
		category = "bots",
		tech_level = 2,
		-- 26 x 31 x 33 elmos
		collider = capsule(26, 31, 33),
		metal_cost = 600,
		energy_cost = 5800,
		buildpower_cost = 9500,
		health = 610,
		acceleration = studs_per_second_squared(0.1265),
		max_speed = studs(54),
		weapons = {
			{
				kind = "missiles",
				damage = 800,
				reload = 8,
				range = studs(1210),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				delivery = missile(
					"short",
					projectile({
						speed = studs(800),
						aoe_radius = aoe(70),
						edge_effectiveness = 0.61,
					})
				),
			},
		} :: { Weapon },
		color = palette.COPPER,
	},

	-- armsnipe, Armada's Sharpshooter: a sniper bot. BAR fires a cannon shell at 3000 elmos a second, which at the
	-- range it shoots from is over in a fraction of a second, so it is a beam here, striking the first solid thing
	-- on its line the instant it fires. It hits very hard, reloads very slowly and pays energy for every shot. BAR
	-- also lets it cloak, which is left out.
	-- bar: armsnipe
	sharpshooter = {
		name = "sharpshooter",
		footing = footing.moves "BOT2",
		weight_class = "light",
		display_name = "Sharpshooter",
		subtitle = "Sniper bot",
		kind = "unit",
		category = "bots",
		tech_level = 2,
		-- 30 x 44 x 30 elmos
		collider = capsule(30, 44, 30),
		metal_cost = 680,
		energy_cost = 20000,
		buildpower_cost = 24000,
		health = 580,
		acceleration = studs_per_second_squared(0.138),
		max_speed = studs(33),
		weapons = {
			{
				kind = "sniper",
				damage = 2500,
				reload = 10,
				range = studs(900),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 500,
				delivery = {
					kind = "beam",
					time = 0.2,
					thickness = 0.12,
					color = Color3.fromRGB(255, 255, 0),
					charged = true,
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- armmav: a bot with a rifle whose shells fly fast and flat, and which mends itself. Everything here is BAR's. The
	-- shell falls under gravity and is aimed along the low arc that lands it on its target, so like any low
	-- shot it needs a clear line, and a friend in the way stops it.
	-- bar: armmav
	gunslinger = {
		name = "gunslinger",
		footing = footing.moves "BOT3",
		display_name = "Gunslinger",
		subtitle = "Solo leveling bot",
		kind = "unit",
		category = "bots",
		tech_level = 2,
		-- 36 x 48 x 36 elmos
		collider = capsule(36, 48, 36),
		metal_cost = 650,
		energy_cost = 11000,
		buildpower_cost = 17000,
		health = 1800,
		autoheal = 50,
		acceleration = studs_per_second_squared(0.138),
		max_speed = studs(50),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 265,
				reload = 1,
				range = studs(365),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "low",
					projectile = projectile({
						speed = shell_speed(studs(600)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(24),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.STEEL_BLUE,
	},

	-- bar: corcan
	sumo = {
		name = "sumo",
		-- corcan.lua's movementclass
		footing = footing.moves "BOT2",
		display_name = "Sumo",
		subtitle = "Armored assault bot",
		kind = "unit",
		category = "bots",
		tech_level = 2,
		collider = capsule(32, 34, 30),
		metal_cost = 560,
		energy_cost = 9300,
		buildpower_cost = 12000,
		health = 6000,
		acceleration = studs_per_second_squared(0.138),
		max_speed = studs(38),
		weapons = {
			{
				kind = "laser",
				damage = 275,
				reload = 0.8,
				range = studs(275),
				turret = { turn_rate = math.rad(150) },
				energy_per_shot = 45,
				delivery = {
					kind = "beam",
					time = 0.3,
					thickness = 0.7,
				},
			},
		} :: { Weapon },
		color = palette.AMBER,
	},

	-- corsumo: the heaviest bot there is, with a laser that is the Sumo's and then some. Everything here is BAR's.
	-- bar: corsumo
	mammoth = {
		name = "mammoth",
		footing = footing.moves "HBOT4",
		display_name = "Mammoth",
		subtitle = "Heavy assault bot",
		weight_class = "heavy",
		kind = "unit",
		category = "bots",
		tech_level = 2,
		-- 38 x 34 x 36 elmos
		collider = capsule(60, 60, 60),
		metal_cost = 2200,
		energy_cost = 35000,
		buildpower_cost = 65000,
		health = 15600,
		acceleration = studs_per_second_squared(0.0552),
		max_speed = studs(23),
		weapons = {
			{
				kind = "laser",
				damage = 302,
				reload = 0.6,
				range = studs(650),
				turret = { turn_rate = math.rad(110) },
				energy_per_shot = 75,
				delivery = {
					kind = "beam",
					time = 0.19,
					thickness = 0.8,
				},
			},
		} :: { Weapon },
		color = palette.AMBER,
	},

	-- bar: armfboy
	fatboy = {
		name = "fatboy",
		footing = footing.moves "HBOT4",
		display_name = "Fatboy",
		subtitle = "Heavy Plasma Bot",
		weight_class = "heavy",
		kind = "unit",
		category = "bots",
		tech_level = 2,
		collider = capsule(60, 60, 60),
		metal_cost = 1400,
		energy_cost = 20000,
		buildpower_cost = 32000,
		health = 7800,
		acceleration = studs_per_second_squared(0.0138),
		max_speed = studs(30),
		weapons = {
			{
				kind = "plasma_cannon",
				damage = 800,
				reload = 7,
				range = studs(700),
				turret = { turn_rate = math.rad(110) },
				energy_per_shot = 0,
				delivery = {
					kind = "lobbed",
					arc = "medium",
					projectile = projectile({
						speed = shell_speed(studs(600)),
						gravity = shell_gravity(studs(MAP_GRAVITY)),
						aoe_radius = aoe(300),
						edge_effectiveness = 0.15,
					}),
				},
			},
		} :: { Weapon },
		color = palette.AMBER,
	},

	-- armsptk, Armada's Recluse: an all-terrain spider that climbs any slope, firing bursts of three rockets that fly the
	-- way the Aggravator's do but reach farther. BAR's launch speed and acceleration are kept; it thrusts for longer
	-- than BAR's three second flight, long enough to reach its range before it starts to fall, and the drag and
	-- gravity are the Aggravator's.
	-- bar: armsptk
	recluse = {
		name = "recluse",
		footing = footing.moves "TBOT3",
		weight_class = "light",
		display_name = "Recluse",
		subtitle = "All-terrain rocket spider",
		kind = "unit",
		category = "bots",
		tech_level = 2,
		-- 42 x 28 x 42 elmos
		collider = capsule(42, 28, 42),
		metal_cost = 400,
		energy_cost = 4500,
		buildpower_cost = 11500,
		health = 1390,
		acceleration = studs_per_second_squared(0.207),
		max_speed = studs(47),
		-- armsptk's `paralyzemultiplier` 0.2
		emp_resistance = 0.8,
		weapons = {
			{
				kind = "rockets",
				damage = 200,
				reload = 3.75,
				burst_count = 3,
				burst_interval = 0.3,
				range = studs(575),
				turret = { turn_rate = math.rad(200) },
				energy_per_shot = 0,
				delivery = {
					kind = "straight",
					guidance = "none",
					projectile = projectile({
						speed = studs(80),
						acceleration = studs(70),
						thrust_time = 3.2,
						gravity = ROCKET_GRAVITY,
						drag = ROCKET_DRAG,
						aoe_radius = aoe(90),
						edge_effectiveness = 0.65,
					}),
				},
			},
		} :: { Weapon },
		color = palette.OLIVE,
	},
}

return table.freeze(defs)
